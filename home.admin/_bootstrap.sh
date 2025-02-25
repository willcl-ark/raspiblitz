#!/bin/bash

# This script runs on every start called by boostrap.service
# see logs with --> tail -n 100 /home/admin/raspiblitz.log

################################
# BASIC SETTINGS
################################

# load codeVersion
source /home/admin/_version.info

# CONFIGFILE - configuration of RaspiBlitz
# used by fresh SD image to recover configuration
# and delivers basic config info for scripts 
configFile="/mnt/hdd/raspiblitz.conf"

# LOGFILE - store debug logs of bootstrap
# resets on every start
logFile="/home/admin/raspiblitz.log"

# INFOFILE - state data from bootstrap
# used by display and later setup steps
infoFile="/home/admin/raspiblitz.info"

# SETUPFILE
# this key/value file contains the state during the setup process
setupFile="/var/cache/raspiblitz/temp/raspiblitz.setup"

# Init boostrap log file
echo "Writing logs to: ${logFile}"
echo "" > $logFile
echo "***********************************************" >> $logFile
echo "Running RaspiBlitz Bootstrap ${codeVersion}" >> $logFile
date >> $logFile
echo "***********************************************" >> $logFile

# set default values for raspiblitz.info
network=""
chain=""
setupStep=0
setupPhase='boot'
fsexpanded=0
# see https://github.com/rootzoll/raspiblitz/issues/1265#issuecomment-813369284
displayClass="lcd"
displayType=""
fundRecovery=0

##############################################
# check raspiblitz.conf for outdated variables
##############################################

# change all cln to cl
# https://github.com/rootzoll/raspiblitz/pull/2575#issuecomment-927261596
if [ $(grep -c cln < /mnt/hdd/raspiblitz.conf) -gt 0 ];then
  sudo sed -i 's/cln/cl/g' /mnt/hdd/raspiblitz.conf
  sudo sed -i 's/cln/cl/g' _aliases

  sudo sed -i 's/cln/cl/g' /home/bitcoin/.lightning/config 
  sudo sed -i 's/cln/cl/g' /home/bitcoin/.lightning/testnet/config 
  sudo sed -i 's/cln/cl/g' /home/bitcoin/.lightning/signet/config 
 
  sudo -u bitcoin mv /home/bitcoin/cln-plugins-available /home/bitcoin/cl-plugins-available
  sudo -u bitcoin mv /home/bitcoin/cln-plugins-enabled /home/bitcoin/cl-plugins-enabled
  sudo -u bitcoin mv /home/bitcoin/tcln-plugins-enabled /home/bitcoin/tcl-plugins-enabled
  sudo -u bitcoin mv /home/bitcoin/scln-plugins-enabled /home/bitcoin/scl-plugins-enabled

  sudo sed -i 's/cln/cl/g'  /etc/systemd/system/lightningd.service
  sudo sed -i 's/cln/cl/g'  /etc/systemd/system/tlightningd.service
  sudo sed -i 's/cln/cl/g'  /etc/systemd/system/slightningd.service

  sudo /home/admin/config.scripts/blitz.shutdown.sh reboot
fi

################################
# INIT raspiblitz.info
################################

# try to load old values if available (overwrites defaults)
source ${infoFile} 2>/dev/null

# try to load config values if available (config overwrites info)
source ${configFile} 2>/dev/null

# get first basic network info
source <(/home/admin/config.scripts/internet.sh status)

# get basic hardware info
source <(/home/admin/config.scripts/blitz.hardware.sh status)

# get basic dns info
source <(sudo /home/admin/config.scripts/internet.dns.sh test nodialog)

# resetting info file
echo "Resetting the InfoFile: ${infoFile}"
echo "state=starting" > $infoFile
echo "message=" >> $infoFile
echo "baseimage=${baseimage}" >> $infoFile
echo "cpu=${cpu}" >> $infoFile
echo "board=${board}" >> $infoFile
echo "ramMB=${ramMB}" >> $infoFile
echo "ramGB=${ramGB}" >> $infoFile
echo "network=${network}" >> $infoFile
echo "chain=${chain}" >> $infoFile
echo "localip='${localip}'" >> $infoFile
echo "online='${online}'" >> $infoFile
echo "dnsworking=${dnsworking}" >> $infoFile
echo "fsexpanded=${fsexpanded}" >> $infoFile
echo "displayClass=${displayClass}" >> $infoFile
echo "displayType=${displayType}" >> $infoFile
echo "setupStep=${setupStep}" >> $infoFile
echo "setupPhase=${setupPhase}" >> $infoFile
echo "fundRecovery=${fundRecovery}" >> $infoFile
if [ "${setupStep}" != "100" ]; then
  echo "hostname=${hostname}" >> $infoFile
fi
sudo chmod 664 ${infoFile}

######################################
# CHECK SD CARD INCONSISTENT STATE

# make sure SSH server is configured & running
sudo /home/admin/config.scripts/blitz.ssh.sh checkrepair >> ${logFile}

# when a file 'stop' is on the sd card boot partition - stop for manual provision
flagExists=$(sudo ls /boot/stop | grep -c 'stop')
if [ "${flagExists}" == "1" ]; then
  sudo rm /boot/stop
  sed -i "s/^state=.*/state=stop/g" ${infoFile}
  sed -i "s/^message=.*/message='stopped for manual provision'/g" ${infoFile}
  echo "INFO: 'bootstrap stopped - run release after manual provison'" >> ${logFile}
  exit 0
fi

# when the provision did not ran thru without error (ask user for fresh sd card)
provisionFlagExists=$(sudo ls /home/admin/provision.flag | grep -c 'provision.flag')
if [ "${provisionFlagExists}" == "1" ]; then
  sudo systemctl stop ${network}d 2>/dev/null
  sudo systemctl stop lnd 2>/dev/null
  sed -i "s/^state=.*/state=inconsistentsystem/g" ${infoFile}
  sed -i "s/^message=.*/message='provision did not ran thru'/g" ${infoFile}
  echo "FAIL: 'provision did not ran thru' - need fresh sd card!" >> ${logFile}
  exit 1
fi

######################################
# SECTION FOR POSSIBLE REBOOT ACTIONS
systemInitReboot=0

################################
# FORCED SWITCH TO HDMI
# if a file called 'hdmi' gets
# placed onto the boot part of
# the sd card - switch to hdmi
################################

forceHDMIoutput=$(sudo ls /boot/hdmi* 2>/dev/null | grep -c hdmi)
if [ ${forceHDMIoutput} -eq 1 ]; then
  # delete that file (to prevent loop)
  sudo rm /boot/hdmi*
  # switch to HDMI what will trigger reboot
  echo "HDMI switch found ... activating HDMI display output & reboot" >> $logFile
  sudo /home/admin/config.scripts/blitz.display.sh set-display hdmi >> $logFile
  systemInitReboot=1
  sed -i "s/^message=.*/message='HDMI'/g" ${infoFile}
else
  echo "No HDMI switch found. " >> $logFile
fi

################################
# FS EXPAND
# if a file called 'ssh.reset' gets
# placed onto the boot part of
# the sd card - delete old ssh data
################################

source <(sudo /home/admin/config.scripts/blitz.bootdrive.sh status)
if [ "${needsExpansion}" == "1" ] && [ "${fsexpanded}" == "0" ]; then
  echo "FSEXPAND needed ... starting process" >> $logFile
  sudo /home/admin/config.scripts/blitz.bootdrive.sh status >> $logFile
  sudo /home/admin/config.scripts/blitz.bootdrive.sh fsexpand >> $logFile
  systemInitReboot=1
  sed -i "s/^message=.*/message='FSEXPAND'/g" ${infoFile}
elif [ "${tooSmall}" == "1" ]; then
  echo "!!! FAIL !!!!!!!!!!!!!!!!!!!!" >> $logFile
  echo "SDCARD TOO SMALL 16G minimum" >> $logFile
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >> $logFile
  sed -i "s/^state=.*/state=sdtoosmall/g" ${infoFile}
  echo "System stopped. Please cut power." >> $logFile
  sleep 6000
  sudo shutdown -r now
  slepp 100
  exit 1
else
  echo "No FS EXPAND needed. needsExpansion(${needsExpansion}) fsexpanded(${fsexpanded})" >> $logFile
fi

################################
# SSH SERVER CERTS RESET
# if a file called 'ssh.reset' gets
# placed onto the boot part of
# the sd card - delete old ssh data
################################

sshReset=$(sudo ls /boot/ssh.reset* 2>/dev/null | grep -c reset)
if [ ${sshReset} -eq 1 ]; then
  # delete that file (to prevent loop)
  sudo rm /boot/ssh.reset* >> $logFile
  # delete ssh certs
  echo "SSHRESET switch found ... stopping SSH and deleting old certs" >> $logFile
  sudo /home/admin/config.scripts/blitz.ssh.sh renew >> $logFile
  sudo /home/admin/config.scripts/blitz.ssh.sh backup >> $logFile
  systemInitReboot=1
  sed -i "s/^message=.*/message='SSHRESET'/g" ${infoFile}
else
  echo "No SSHRESET switch found. " >> $logFile
fi

################################
# UASP FIX - first try
# if HDD is connected on start
################################
source <(sudo /home/admin/config.scripts/blitz.datadrive.sh uasp-fix)
if [ "${neededReboot}" == "1" ]; then
  echo "UASP FIX applied (1st-try) ... reboot needed." >> $logFile
  sed -i "s/^message=.*/message='UASP'/g" ${infoFile}
  systemInitReboot=1
else
  echo "No UASP FIX needed (1st-try)." >> $logFile
fi

######################################
# CHECK IF REBOOT IS NEEDED
# from actions above

if [ "${systemInitReboot}" == "1" ]; then
  sudo cp ${logFile} /home/admin/raspiblitz.systeminit.log
  sudo sed -i "s/^state=.*/state=reboot/g" ${infoFile}
  sleep 8
  sudo shutdown -r now
  sleep 100
  exit 0
fi

################################
# BOOT LOGO
################################

# display 3 secs logo - try to kickstart LCD
# see https://github.com/rootzoll/raspiblitz/issues/195#issuecomment-469918692
# see https://github.com/rootzoll/raspiblitz/issues/647
# see https://github.com/rootzoll/raspiblitz/pull/1580
randnum=$(shuf -i 0-7 -n 1)
/home/admin/config.scripts/blitz.display.sh image /home/admin/raspiblitz/pictures/startlogo${randnum}.png
sleep 5
/home/admin/config.scripts/blitz.display.sh hide

################################
# CLEANING BOOT SYSTEM
################################

# resetting start count files
echo "SYSTEMD RESTART LOG: blockchain (bitcoind/litecoind)" > /home/admin/systemd.blockchain.log
echo "SYSTEMD RESTART LOG: lightning (LND)" > /home/admin/systemd.lightning.log
sudo chmod 666 /home/admin/systemd.blockchain.log
sudo chmod 666 /home/admin/systemd.lightning.log

# Emergency cleaning logs when over 1GB (to prevent SD card filling up)
# see https://github.com/rootzoll/raspiblitz/issues/418#issuecomment-472180944
echo "*** Checking Log Size ***"
logsMegaByte=$(sudo du -c -m /var/log | grep "total" | awk '{print $1;}')
if [ ${logsMegaByte} -gt 1000 ]; then
  echo "WARN !! Logs /var/log in are bigger then 1GB"
  echo "ACTION --> DELETED ALL LOGS"
  if [ -d "/var/log/nginx" ]; then
    nginxLog=1
    echo "/var/log/nginx is present"
  fi
  sudo rm -r /var/log/*
  sudo service rsyslog restart
  if [ $nginxLog == 1 ]; then
    sudo mkdir /var/log/nginx
    echo "Recreated /var/log/nginx"
  fi
  sleep 3
  echo "WARN !! Logs in /var/log in were bigger then 1GB and got emergency delete to prevent fillup."
  echo "If you see this in the logs please report to the GitHub issues, so LOG config needs to be optimized."
else
  echo "OK - logs are at ${logsMegaByte} MB - within safety limit"
fi
echo ""

###############################
# WAIT FOR ALL SERVICES

# get the state of data drive
source <(sudo /home/admin/config.scripts/blitz.datadrive.sh status)

################################
# WAIT LOOP: HDD CONNECTED
################################

echo "Waiting for HDD/SSD ..." >> $logFile
sudo ls -la /etc/ssh >> $logFile 
until [ ${isMounted} -eq 1 ] || [ ${#hddCandidate} -gt 0 ]
do

  # recheck HDD/SSD
  source <(sudo /home/admin/config.scripts/blitz.datadrive.sh status)
  echo "isMounted: $isMounted"
  echo "hddCandidate: $hddCandidate"

  # in case of HDD analyse ERROR
  if [ "${hddError}" != "" ]; then
    echo "FAIL - error on HDD analysis: ${hddError}" >> $logFile
    sed -i "s/^state=.*/state=errorHDD/g" ${infoFile}
    sed -i "s/^message=.*/message='${hddError}'/g" ${infoFile}
  elif [ "${isMounted}" == "0" ] && [ "${hddCandidate}" == "" ]; then
    sed -i "s/^state=.*/state=noHDD/g" ${infoFile}
    sed -i "s/^message=.*/message='>=1TB'/g" ${infoFile}
  fi

  # wait for next check
  sleep 2

done
echo "HDD/SSD connected: ${$hddCandidate}" >> $logFile

# write info for LCD
sed -i "s/^state=.*/state=system-init/g" ${infoFile}
sed -i "s/^message=.*/message='please wait'/g" ${infoFile}

####################################
# WIFI RESTORE from HDD works with
# mem copy from datadrive inspection
####################################

# check if there is a WIFI configuration to backup or restore
/home/admin/config.scripts/internet.wifi.sh backup-restore >> $logFile

################################
# UASP FIX - second try
# when HDD gets connected later
################################
sed -i "s/^message=.*/message='checking HDD'/g" ${infoFile}
source <(sudo /home/admin/config.scripts/blitz.datadrive.sh uasp-fix)
if [ "${neededReboot}" == "1" ]; then
  echo "UASP FIX applied (2nd-try) ... reboot needed." >> $logFile
  sudo cp ${logFile} ${logFile}.uasp
  sudo sed -i "s/^state=.*/state=reboot/g" ${infoFile}
  sleep 8
  sudo shutdown -r now
  sleep 100
  exit 0
else
  echo "No UASP FIX needed (2nd-try)." >> $logFile
fi

###################################
# WAIT LOOP: LOCALNET / INTERNET
# after HDD > can contain WIFI conf
###################################
gotLocalIP=0
until [ ${gotLocalIP} -eq 1 ]
do

  # get latest network info & update raspiblitz.info
  source <(/home/admin/config.scripts/internet.sh status)
  sed -i "s/^localip=.*/localip='${localip}'/g" ${infoFile}

  # check state of network
  if [ ${dhcp} -eq 0 ]; then
    # display user waiting for DHCP
    sed -i "s/^state=.*/state=noDHCP/g" ${infoFile}
    sed -i "s/^message=.*/message='Waiting for DHCP'/g" ${infoFile}
  elif [ ${#localip} -eq 0 ]; then
    configWifiExists=$(sudo cat /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null| grep -c "network=")
    if [ ${configWifiExists} -eq 0 ]; then
      # display user to connect LAN
      sed -i "s/^state=.*/state=noIP-LAN/g" ${infoFile}
      sed -i "s/^message=.*/message='Connect the LAN/WAN'/g" ${infoFile}
    else
      # display user that wifi settings are not working
      sed -i "s/^state=.*/state=noIP-WIFI/g" ${infoFile}
      sed -i "s/^message=.*/message='WIFI Settings not working'/g" ${infoFile}
    fi
  elif [ ${online} -eq 0 ]; then
    # display user that wifi settings are not working
    sed -i "s/^state=.*/state=noInternet/g" ${infoFile}
    sed -i "s/^message=.*/message='No connection to Internet'/g" ${infoFile}
  else
    gotLocalIP=1
  fi
  sleep 1
done

# write info for LCD
sed -i "s/^state=.*/state=inspect-hdd/g" ${infoFile}
sed -i "s/^message=.*/message='please wait'/g" ${infoFile}

# get fresh info about data drive to continue
source <(sudo /home/admin/config.scripts/blitz.datadrive.sh status)

echo "isMounted: $isMounted" >> $logFile

# check if UASP is already deactivated (on RaspiOS)
# https://www.pragmaticlinux.com/2021/03/fix-for-getting-your-ssd-working-via-usb-3-on-your-raspberry-pi/
cmdlineExists=$(sudo ls /boot/cmdline.txt 2>/dev/null | grep -c "cmdline.txt")
if [ ${cmdlineExists} -eq 1 ] && [ ${#hddAdapterUSB} -gt 0 ] && [ ${hddAdapterUSAP} -eq 0 ]; then
  echo "Checking for UASP deactivation ..." >> $logFile
  usbQuirkActive=$(sudo cat /boot/cmdline.txt | grep -c "usb-storage.quirks=")
  # check if its maybe other device
  usbQuirkDone=$(sudo cat /boot/cmdline.txt | grep -c "usb-storage.quirks=${hddAdapterUSB}:u")
  if [ ${usbQuirkActive} -gt 0 ] && [ ${usbQuirkDone} -eq 0 ]; then
    # remove old usb-storage.quirks
    sudo sed -i "s/usb-storage.quirks=[^ ]* //g" /boot/cmdline.txt
  fi 
  if [ ${usbQuirkDone} -eq 0 ]; then
    # add new usb-storage.quirks
    sudo sed -i "1s/^/usb-storage.quirks=${hddAdapterUSB}:u /" /boot/cmdline.txt
    sudo cat /boot/cmdline.txt >> $logFile
    # go into reboot to activate new setting
    echo "DONE deactivating UASP for ${hddAdapterUSB} ... one more reboot needed ... " >> $logFile
    sudo cp ${logFile} ${logFile}.uasp
    sudo shutdown -r now
    sleep 100
  fi
else 
  echo "Skipping UASP deactivation ... cmdlineExists(${cmdlineExists}) hddAdapterUSB(${hddAdapterUSB}) hddAdapterUSAP(${hddAdapterUSAP})" >> $logFile
fi

# check if the HDD is auto-mounted ( auto-mounted = setup-done)
echo "HDD already part of system: $isMounted" >> $logFile

############################
############################
# WHEN SETUP IS NEEDED  
############################

if [ ${isMounted} -eq 0 ]; then

  # temp mount the HDD
  echo "Temp mounting (1) data drive ($hddCandidate)" >> $logFile
  if [ "${hddFormat}" != "btrfs" ]; then
    source <(/home/admin/config.scripts/blitz.datadrive.sh tempmount ${hddPartitionCandidate})
  else
    source <(/home/admin/config.scripts/blitz.datadrive.sh tempmount ${hddCandidate})
  fi
  echo "Temp mounting (1) result: ${isMounted}" >> $logFile

  # write data needed for setup process into raspiblitz.info
  echo "hddCandidate='${hddCandidate}'" >> ${infoFile}
  echo "hddGigaBytes=${hddGigaBytes}" >> ${infoFile}
  echo "hddBlocksBitcoin=${hddBlocksBitcoin}" >> ${infoFile}
  echo "hddBlocksLitecoin=${hddBlocksLitecoin}" >> ${infoFile}
  echo "hddGotMigrationData=${hddGotMigrationData}" >> ${infoFile}
  echo ""
  echo "HDD is there but not AutoMounted yet - Waiting for user Setup/Update" >> $logFile

  # add some debug info to logfile
  echo "# df " >> ${logFile}
  df >> ${logFile}
  echo "# lsblk -o NAME,FSTYPE,LABEL " >> ${logFile}
  lsblk -o NAME,FSTYPE,LABEL >> ${logFile}
  echo "# /home/admin/config.scripts/blitz.datadrive.sh status"
  /home/admin/config.scripts/blitz.datadrive.sh status >> ${logFile}

  # determine correct setup phase
  infoMessage="Please Login for Setup"
  setupPhase="setup"
  if [ "${hddGotMigrationData}" != "" ]; then
    infoMessage="Please Login for Migration"
    setupPhase="migration"
  elif [ "${hddRaspiData}" == "1" ]; then

    # INIT OLD SSH HOST KEYS on Update/Recovery to prevent "Unknown Host" on ssh client
    echo "COPY und Activating old SSH host keys" >> $logFile
    /home/admin/config.scripts/blitz.ssh.sh restore >> $logFile

    # determine if this is a recovery or an update
    # TODO: improve version/update detection later
    isRecovery=$(echo "${hddRaspiVersion}" | grep -c "${codeVersion}")
    if [ "${isRecovery}" == "1" ]; then
      infoMessage="Please Login for Recovery"
      setupPhase="recovery"
    else
      infoMessage="Please Login for Update"
      setupPhase="update"
    fi

  fi

  # signal "WAIT LOOP: SETUP" to LCD, SSH & WEBAPI
  echo "Displaying Info Message: ${infoMessage}" >> $logFile
  sed -i "s/^state=.*/state=waitsetup/g" ${infoFile}
  sed -i "s/^message=.*/message='${infoMessage}'/g" ${infoFile}
  sed -i "s/^setupPhase=.*/setupPhase='${setupPhase}'/g" ${infoFile}

  #############################################
  # WAIT LOOP: USER SETUP/UPDATE/MIGRATION
  # until SSH or WEBUI setup data is available
  #############################################

  echo "## WAIT LOOP: USER SETUP/UPDATE/MIGRATION" >> ${logFile}
  until [ "${state}" == "waitprovision" ]
  do

    # get fresh info about data drive (in case the hdd gets disconnected)
    source <(sudo /home/admin/config.scripts/blitz.datadrive.sh status)
    if [ "${hddCandidate}" == "" ]; then
      echo "!!! WARNING !!! Lost HDD connection .. triggering reboot, to restart system-init." >> ${logFile}
      sed -i "s/^state=.*/state=errorHDD/g" ${infoFile}
      sed -i "s/^message=.*/message='lost HDD - rebooting'/g" ${infoFile}
      sudo cp ${logFile} ${logFile}.error
      sleep 8
      sudo shutdown -r now
      sleep 100
      exit 0
    fi

    # detect if network get deconnected again
    # --> "removing network cable" can be used as signal to shutdown clean on test startup
    source <(/home/admin/config.scripts/internet.sh status)
    if [ "${localip}" == "" ]; then
      sed -i "s/^state=.*/state=errorNetwork/g" ${infoFile}
      sleep 8
      sudo shutdown now
      sleep 100
      exit 0
    fi

    # give the loop a little bed time
    sleep 4

    # check info file for updated values
    # especially the state for checking loop
    source ${infoFile}

  done

  #############################################
  # PROVISION PROCESS
  #############################################

  # refresh data from info file
  source ${infoFile}
  echo "# PROVISION PROCESS with setupPhase(${setupPhase})" >> ${logFile}

  # mark system on sd card as in setup process
  echo "the provision process was started but did not finish yet" > /home/admin/provision.flag

  # make sure HDD is mounted (could be freshly formatted by user on last loop)
  source <(/home/admin/config.scripts/blitz.datadrive.sh status)
  echo "Temp mounting (2) data drive ($hddCandidate)" >> ${logFile}
  if [ "${hddFormat}" != "btrfs" ]; then
    source <(sudo /home/admin/config.scripts/blitz.datadrive.sh tempmount ${hddPartitionCandidate})
  else
    source <(sudo /home/admin/config.scripts/blitz.datadrive.sh tempmount ${hddCandidate})
  fi
  echo "Temp mounting (2) result: ${isMounted}" >> ${logFile}

  # check that HDD was temp mounted
  if [ "${isMounted}" != "1"]; then
    sed -i "s/^state=.*/state=errorHDD/g" ${infoFile}
    sed -i "s/^message=.*/message='Was not able to mount HDD (2)'/g" ${infoFile}
    exit 1
  fi

  # make sure all links between directories/drives are correct
  echo "Refreshing links between directories/drives .." >> ${logFile}
  sudo /home/admin/config.scripts/blitz.datadrive.sh link

  # copy over the raspiblitz.conf created from setup to HDD
  configExists=$(ls /mnt/hdd/raspiblitz.conf 2>/dev/null | grep -c "raspiblitz.conf")
  if [ "${configExists}" != "1" ]; then
    sudo cp /var/cache/raspiblitz/temp/raspiblitz.conf ${configFile}
  fi

  # kick-off provision process
  sed -i "s/^state=.*/state=provision/g" ${infoFile}
  sed -i "s/^message=.*/message='Starting Provision'/g" ${infoFile}

  # load setup data
  echo "# Sourcing ${configFile} " >> ${logFile}
  source ${configFile}
  cat ${configFile} >> ${logFile}
  echo "# Sourcing ${setupFile} " >> ${logFile}
  source ${setupFile}
  sed -e '/^password/d' ${setupFile} >> ${logFile}

  # add some debug info to logfile
  echo "# df " >> ${logFile}
  df >> ${logFile}
  echo "# lsblk -o NAME,FSTYPE,LABEL " >> ${logFile}
  lsblk -o NAME,FSTYPE,LABEL >> ${logFile}

  # make sure basic info is in raspiblitz.info
  echo "# Update ${infoFile} " >> ${logFile}
  sudo sed -i "s/^network=.*/network=${network}/g" ${infoFile}
  sudo sed -i "s/^chain=.*/chain=${chain}/g" ${infoFile}
  sudo sed -i "s/^lightning=.*/lightning=${lightning}/g" ${infoFile}
  cat ${infoFile} >> ${logFile}

  # if migrationFile was uploaded - now import it
  echo "# migrationFile(${migrationFile})" >> ${logFile}
  if [ "${migrationFile}" != "" ]; then
    sed -i "s/^message=.*/message='Unpacking Migration Data'/g" ${infoFile}
    /home/admin/config.scripts/blitz.migration.sh import "${migrationFile}" >> ${logFile}
    sed -i "s/^setupPhase=.*/setupPhase='recovery'/g" ${infoFile}
    setupPhase="recovery"
  fi

  ###################################
  # Set Password A (in all cases)
  
  if [ "${passwordA}" == "" ]; then
    sed -i "s/^state=.*/state=error/g" ${infoFile}
    sed -i "s/^message=.*/message='config: missing passwordA'/g" ${infoFile}
    echo "FAIL see ${logFile}"
    echo "FAIL: missing passwordA in (${setupFile})!" >> ${logFile}
    exit 1
  fi

  echo "# setting PASSWORD A" >> ${logFile}
  sudo /home/admin/config.scripts/blitz.setpassword.sh a "${passwordA}" >> ${logFile}

  # if setup - run provision setup first
  if [ "${setupPhase}" == "setup" ]; then
    echo "Calling _provision.setup.sh for basic setup tasks .." >> $logFile
    sed -i "s/^message=.*/message='Provision Setup'/g" ${infoFile}
    /home/admin/_provision.setup.sh
    errorState=$?
    sudo cat /home/admin/raspiblitz.provision-setup.log
    if [ "$errorState" != "0" ]; then
      echo "EXIT _provision.setup.sh BECAUSE OF ERROR STATE ($errorState)" >> $logFile
      echo "This can also happen if _provision.setup.sh has syntax errors" >> $logFile
      sed -i "s/^state=.*/state='error'/g" ${infoFile}
      sed -i "s/^message=.*/message='_provision.setup.sh fail'/g" ${infoFile}
      exit 1
    fi
  fi

  # if migration from other nodes - run the migration provision first
  if [ "${setupPhase}" == "migration" ]; then
    echo "Calling _provision.migration.sh for possible migrations .." >> $logFile
    sed -i "s/^message=.*/message='Provision migration'/g" ${infoFile}
    /home/admin/_provision.migration.sh
    errorState=$?
    cat /home/admin/raspiblitz.provision-migration.log
    if [ "$errorState" != "0" ]; then
      echo "EXIT _provision.migration.sh BECAUSE OF ERROR STATE ($errorState)" >> $logFile
      echo "This can also happen if _provision.migration.sh has syntax errros" >> $logFile
      sed -i "s/^state=.*/state='error'/g" ${infoFile}
      sed -i "s/^message=.*/message='_provision.migration.sh fail'/g" ${infoFile}
      exit 1
    fi
  fi

  # if update/recovery/migration-followup
  if [ "${setupPhase}" == "update" ] || [ "${setupPhase}" == "recovery" ] || [ "${setupPhase}" == "migration" ]; then
    echo "Calling _provision.update.sh .." >> $logFile
    sed -i "s/^message=.*/message='Provision Update/Recovery/Migration'/g" ${infoFile}
    /home/admin/_provision.update.sh
    errorState=$?
    cat /home/admin/raspiblitz.provision-update.log
    if [ "$errorState" != "0" ]; then
      echo "EXIT _provision.update.sh BECAUSE OF ERROR STATE ($errorState)" >> $logFile
      echo "This can also happen if _provision.update.sh has syntax errors" >> $logFile
      sed -i "s/^state=.*/state='error'/g" ${infoFile}
      sed -i "s/^message=.*/message='_provision.update.sh fail'/g" ${infoFile}
      exit 1
    fi
  fi
  
  # finalize provisioning
  echo "Calling _bootstrap.provision.sh for general system provisioning (${setupPhase}) .." >> $logFile
  sed -i "s/^message=.*/message='Provision Basics'/g" ${infoFile}
  /home/admin/_provision_.sh
  errorState=$?
  if [ "$errorState" != "0" ]; then
    echo "EXIT _provision_.sh BECAUSE OF ERROR STATE ($errorState)" >> $logFile
    echo "This can also happen if _provision_.sh has syntax errors" >> $logFile
    sed -i "s/^state=.*/state='error'/g" ${infoFile}
    sed -i "s/^message=.*/message='_provision_.sh fail'/g" ${infoFile}
    exit 1
  fi

  # everyone can read the config but it can only be
  # edited/written by root ot admin user (part of group sudo)
  sudo chown root:sudo ${configFile}
  sudo chmod 664 ${configFile}

  # delete provision in progress flag
  sudo rm /home/admin/provision.flag

  # mark provision process done
  sed -i "s/^message=.*/message='Provision Done'/g" ${infoFile}

  # wait until syncProgress is available (neeed for final dialogs)
  while [ "${syncProgress}" == "" ]
  do
    echo "# Waiting for blockchain sync progress info ..." >> $logFile
    source <(sudo /home/admin/config.scripts/blitz.statusscan.sh)
    sed -i "s/^state=.*/state=waitsync/g" ${infoFile}
    sleep 2
  done

  ###################################################
  # HANDOVER TO FINAL SETUP CONTROLLER
  ###################################################

  echo "# HANDOVER TO FINAL SETUP CONTROLLER ..." >> $logFile
  sed -i "s/^state=.*/state=waitfinal/g" ${infoFile}
  sed -i "s/^message=.*/message='Setup Done'/g" ${infoFile}

  # system has to wait before reboot to present like seed words and other info/options to user
  echo "BOOTSTRAP EXIT ... waiting for final setup controller to initiate final reboot." >> $logFile
  exit 1

else

  ############################
  ############################
  # NORMAL START BOOTSTRAP (not executed after setup)
  # Blockchain & Lightning not running
  ############################

  #################################
  # FIX BLOCKCHAINDATA OWNER (just in case)
  # https://github.com/rootzoll/raspiblitz/issues/239#issuecomment-450887567
  #################################
  sudo chown bitcoin:bitcoin -R /mnt/hdd/bitcoin 2>/dev/null

  #################################
  # FIX BLOCKING FILES (just in case)
  # https://github.com/rootzoll/raspiblitz/issues/1901#issue-774279088
  # https://github.com/rootzoll/raspiblitz/issues/1836#issue-755342375
  sudo rm -f /mnt/hdd/bitcoin/bitcoind.pid 2>/dev/null
  sudo rm -f /mnt/hdd/bitcoin/.lock 2>/dev/null

  ################################
  # DELETE LOG & LOCK FILES
  ################################
  # LND and Blockchain Errors will be still in systemd journals

  # /mnt/hdd/bitcoin/debug.log
  sudo rm /mnt/hdd/${network}/debug.log 2>/dev/null
  # /mnt/hdd/lnd/logs/bitcoin/mainnet/lnd.log
  sudo rm /mnt/hdd/lnd/logs/${network}/${chain}net/lnd.log 2>/dev/null
  # https://github.com/rootzoll/raspiblitz/issues/1700
  sudo rm /mnt/storage/app-storage/electrs/db/mainnet/LOCK 2>/dev/null

fi

##############################
##############################
# BOOSTRAP IN EVERY SITUATION
##############################

sed -i "s/^setupPhase=.*/setupPhase='starting'/g" ${infoFile}

# if a WIFI config exists backup to HDD
configWifiExists=$(sudo cat /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null| grep -c "network=")
if [ ${configWifiExists} -eq 1 ]; then
  echo "Making Backup Copy of WIFI config to HDD" >> $logFile
  sudo cp /etc/wpa_supplicant/wpa_supplicant.conf /mnt/hdd/app-data/wpa_supplicant.conf
fi

# make sure lndAddress & lndPort exist in configfile
valueExists=$(cat ${configFile} | grep -c 'lndPort=')
if [ ${valueExists} -eq 0 ]; then
  lndPort=$(sudo cat /mnt/hdd/lnd/lnd.conf | grep "^listen=*" | cut -f2 -d':')
  if [ ${#lndPort} -eq 0 ]; then
    lndPort="9735"
  fi
  echo "lndPort='${lndPort}'" >> ${configFile}
fi
valueExists=$(cat ${configFile} | grep -c 'lndAddress=')
if [ ${valueExists} -eq 0 ]; then
  echo "lndAddress=''" >> ${configFile}
fi

# load data from config file fresh
echo "load configfile data" >> $logFile
source ${configFile}

# update public IP on boot - set to domain if available
/home/admin/config.scripts/internet.sh update-publicip ${lndAddress} 

# make constant UASP entry in raspiblitz.conf if still done by flag file
# uaspForced comes from blitz.datadrive.sh status
if [ ${uaspForced} -eq 1 ]; then
  entryExists=$(cat /mnt/hdd/raspiblitz.conf 2>/dev/null | grep -c 'forceUasp=on')
  if [ ${entryExists} -eq 0 ]; then
      sudo sed -i '/forceUasp=.*/d' /mnt/hdd/raspiblitz.conf
      echo "forceUasp=on" >> /mnt/hdd/raspiblitz.conf
      echo "DONE forceUasp=on recorded in raspiblitz.conf" >> $logFile
  fi
fi

#################################
# MAKE SURE USERS HAVE LATEST LND CREDENTIALS
#################################
source ${configFile}
if [ ${#network} -gt 0 ] && [ ${#chain} -gt 0 ]; then

  echo "running LND users credentials update" >> $logFile
  sudo /home/admin/config.scripts/lnd.credentials.sh sync >> $logFile

else 
  echo "skipping LND credentials sync" >> $logFile
fi

################################
# MOUNT BACKUP DRIVE
# if "localBackupDeviceUUID" is set in
# raspiblitz.conf mount it on boot
################################
source ${configFile}
echo "Checking if additional backup device is configured .. (${localBackupDeviceUUID})" >> $logFile
if [ "${localBackupDeviceUUID}" != "" ] && [ "${localBackupDeviceUUID}" != "off" ]; then
  echo "Yes - Mounting BackupDrive: ${localBackupDeviceUUID}" >> $logFile
  sudo /home/admin/config.scripts/blitz.backupdevice.sh mount >> $logFile
else
  echo "No additional backup device was configured." >> $logFile
fi

#####################################
# CLEAN HDD TEMP
#####################################

echo "CLEANING TEMP DRIVE/FOLDER" >> $logFile
source <(sudo /home/admin/config.scripts/blitz.datadrive.sh clean temp)
if [ ${#error} -gt 0 ]; then
  echo "FAIL: ${error}" >> $logFile
else
  echo "OK: Temp cleaned" >> $logFile
fi

###############################
# RAID data check (BRTFS)
###############################
# see https://github.com/rootzoll/raspiblitz/issues/360#issuecomment-467698260

if [ ${isRaid} -eq 1 ]; then
  echo "TRIGGERING BTRFS RAID DATA CHECK ..."
  echo "Check status with: sudo btrfs scrub status /mnt/hdd/"
  sudo btrfs scrub start /mnt/hdd/
fi

######################################
# PREPARE SUBSCRIPTIONS DATA DIRECTORY
######################################

if [ -d "/mnt/hdd/app-data/subscriptions" ]; then
  echo "OK: subscription data directory exists"
else
  echo "CREATE: subscription data directory"
  sudo mkdir /mnt/hdd/app-data/subscriptions
  sudo chown admin:admin /mnt/hdd/app-data/subscriptions
fi

# make sure that bitcoin service is active
sudo systemctl enable ${network}d

# make sure setup/provision is marked as done
sudo rm /home/admin/provision.flag
sed -i "s/^setupPhase=.*/setupPhase='done'/g" ${infoFile}
sed -i "s/^state=.*/state=ready/g" ${infoFile}
sed -i "s/^message=.*/message='Node Running'/g" ${infoFile}

echo "DONE BOOTSTRAP" >> $logFile
exit 0
