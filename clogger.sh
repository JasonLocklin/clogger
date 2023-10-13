#!/bin/bash

# Set some defaults in case they are not in the cfg
modes=("CW" "SSB" "FT8")
mode_index=0
mode=${modes[0]}
myagn="?"
rigctl="./rigctl"
keyer="python keyer.py"
fifo="false"
statusbar="true"

# load config elements
source clogger.cfg

if [ -z ${station_call} ]
then
  station_call="$mycall"
fi

if ! [[ "${modes[*]}" =~ "CW" ]]
then
  usekeyer="false"
  cwdevice=""
fi

source "$contest"
clogger_version="1"

# turn on or off verbose debug logs
debugon="true"
debuglog="./debug"
echo "" > "$debuglog"

#FIFO location
folder="./fifo"

# This function reads keys, including special function keys
readkey() {
  debug "${FUNCNAME[0]}"
  local key settings
  settings=$(stty -g)             # save terminal settings
  stty -icanon -echo min 0        # disable buffering/echo, allow read to poll
  dd count=1 > /dev/null 2>&1     # Throw away anything currently in the buffer
  stty min 1                      # Don't allow read to poll anymore
  key=$(dd count=1 2> /dev/null)  # do a single read(2) call
  stty "$settings"                # restore terminal settings
  printf "%s" "$key"
  debug "rawkey: '$key'"
}

# Use tput to support portable multi char keypresses
# TERM has to be set correctly for this to work.
initkeys() {
  debug "${FUNCNAME[0]}"
  tput init
  f1=$(tput kf1)
  f2=$(tput kf2)
  f3=$(tput kf3)
  f4=$(tput kf4)
  f5=$(tput kf5)
  f6=$(tput kf6)
  f7=$(tput kf7)
  f8=$(tput kf8)
  f9=$(tput kf9)
  back=$(tput kbs)
  enter=$(tput nel)
  escape=$'\e'
  tab=$'\t'
}

# takes a single argument of the keyvalue (from readkey)
# designed to be called using command substitution
# e.g.:  mappedkey=$(mapkey "$key")
mapkey() {
  debug "${FUNCNAME[0]}"
  case "$1" in
    "$f1") echo "f1";;
    "$f2") echo "f2";;
    "$f3") echo "f3";;
    "$f4") echo "f4";;
    "$f5") echo "f5";;
    "$f6") echo "f6";;
    "$f7") echo "f7";;
    "$f8") echo "f8";;
    "$f9") echo "f9";;
    "$enter") echo "enter";;
    "$back") echo "back";;
    "$escape") echo "escape";;
    "$tab") echo "tab";;
    " ") echo "space";;
    *)
       if [[ "$1" =~ ^[[:alnum:]]*$ ]] || [[ "$1" =~ ^[[:punct:]]*$ ]]
       then
         echo "$1"
       fi
       ;;
  esac
}

debug() {
  if [[ "$debugon" == "true" ]]
  then
    echo "$1" >> "$debuglog"
  fi
}

# this expects the keyname as arg1, and the logmode as arg2
# these functions are mapped in log.cfg in the function map section
# if no function is found, the key appendbuff is called
execfunc() {
  debug "${FUNCNAME[0]}"
  # create a named function based on the key and mode
  func="$2$1"
  debug "$func"
  if [[ "$func" =~ ^[[:alnum:]]*$ ]] && [ -n "$(type -t ${!func})" ] && [ "$(type -t ${!func})" = function ]
  then
    # when running the sendcq function, run it in background and capture the pid
    if [[ "${!func}" == "sendcq" ]]
    then
      setband
      ${!func} &
      cqpid=$!
      debug "sendcq cqpid: $cqpid"
    else
      ${!func}
    fi
  else
    debug "appendbuff $1"
    appendbuff "$1"
  fi
}

killcqpid() {
  debug "${FUNCNAME[0]}"
  if [[ ! -z "$cqpid" ]]
  then
    debug "kill -9 $cqpid"
    kill -9 $cqpid
    wait $pid
    cqpid=""
  fi
}

# open the key
openkey() {
  debug "${FUNCNAME[0]}"
  $keyer -o -t "off"
}

# arg1: text arg2: async/sync (default to async)
cwsend() {
  debug "${FUNCNAME[0]}"
  debug "$1 usekeyer=$usekeyer"
  debug "$mode"
  if [[ ! -z $1 ]] && [[ "$usekeyer" == "true" ]] && [[ "$mode" == "CW" ]]
  then
    debug "passed cwsend tests"
    lastaction="$1"
    drawlastaction
    if [[ "$keywithhamlib" != "true" ]]
    then
      debug "keying with cwkeyer"
      if [[ "$2" == "sync" ]]
      then
        debug "$keyer -w $speed -d $cwdevice -t \"$1\""
        $keyer -w $speed -d $cwdevice -t "$1"
      else
        debug "$keyer -w $speed -d $cwdevice -t \"$1\" &"
        $keyer -w $speed -d $cwdevice -t "$1" &
      fi
    else
      debug "keying with hamlib"
      if [[ "$2" == "sync" ]]
      then
        rigcommand "b $1"
        rigcommand \wait_morse
      else
        rigcommand "b $1"
      fi
    fi
  fi
}

setwpm() {
  speed="$1"
  if [[ "$keywithhamlib" == "true" ]]
  then
    debug "$rigctl $rigoptions -m $rig -r $rigdevice L KEYSPD $1"
    rigcommand "L KEYSPD $1" 
  fi
  clearbuff
  drawstatus
}

qrq() {
  debug "${FUNCNAME[0]}"
  speed="$(($speed+5))"
  setwpm $speed
}
qrs() {
  debug "${FUNCNAME[0]}"
  speed="$(($speed-5))"
  setwpm $speed
}
runqrq=qrq
sandpqrq=qrq
runqrs=qrs
sandpqrs=qrs

getcall() {
  debug "${FUNCNAME[0]}"
  local val=$(echo "$buff" | cut -d' ' -f1)
  echo "$val"
}

gete1() {
  debug "${FUNCNAME[0]}"
  local val=$(echo "$buff" | cut -d' ' -f2)
  echo "$val"
}

# these are the defined functions that you can map f1-f9 to for each mode
sendbuff() {
  debug "${FUNCNAME[0]}"
  cwsend "$buff"
}

sendcq() {
 debug "${FUNCNAME[0]}"
 while true
 do
   cwsend "$mycq" "sync"
   debug "Sleeping $cqdelay seconds between CQ calls"
   sleep $cqdelay
 done
}

update_exchange(){
  serial_length=${#serial}
  if [ "$serial_length"  == 1 ]
  then
    temp_serial="TT$serial"
  elif [ "$serial_length" == 2 ]
  then
    temp_serial="T$serial"
  else
    temp_serial=$serial
  fi
  debug "temp_serial $temp_serial"
  debug "serial $serial"
  temp_exchange="${myexchange/SERIAL/$temp_serial}"
}

sendexchange() {
  update_exchange
  debug "${FUNCNAME[0]}"
  cwsend "$temp_exchange"
}

sendmycall() {
  setband
  debug "${FUNCNAME[0]}"
  cwsend "$mycall"
}
sendtu() {
  debug "${FUNCNAME[0]}"
  cwsend "TU"
}
sendagn() {
  debug "${FUNCNAME[0]}"
  cwsend "$myagn"
}

parse_rst() {

    # extract RST based on mode
    if [ "$mode" == "CW" ]
    then
      rsts=$(echo "$1" | grep -oP '(\d{3})' | tr "\n" " ")
    elif [ "$mode" == "FT8" ]
    then
      rsts=$(echo "$1" | grep -oP '(\-|\+)\d{1,2}' | tr "\n" " ")
    else
      rsts=$(echo "$1" | grep -oP '(\d{2})' | tr "\n" " ")
    fi

    # assign RST's based on whether you were running, or s&p
    if [ "logmode" == "run" ]
    then
      sentrs=$(echo "$1" | cut -d' ' -f3)
      recvrs=$(echo "$1" | cut -d' ' -f2)
    else
      sentrs=$(echo "$1" | cut -d' ' -f2)
      recvrs=$(echo "$1" | cut -d' ' -f3)
    fi
}

lotw_upload() {
  tqsl -p "$certpass" -d -u -a all -x -l "$lotw_station" "$logfile" 2>lotw_results.txt
  lotw_result=$(grep "Final Status:" lotw_results.txt)
  subbuff="$lotw_result"
  buff=""
  drawbuff
  drawsubmenu
}

logqso() {
  debug "${FUNCNAME[0]}"
  dxcall=$(echo "$buff" | cut -d' ' -f1)

  if [ ! -d "logs" ]
  then
    mkdir logs
  fi

  if [ -z "$dxcall" ]
  then
    return
  fi
  decall="$mycall"
  date=$(date -u +"%Y%m%d")
  timeon=$(date -u +%H%M)
  if [ "$parserst" == "true" ]
  then
    parse_rst "$buff"
    comments=$(echo "$buff" | cut -d' ' -f4- | tr -cd "[:print:]")
  else
    sentrs="599"
    recvrs="599"
    # strip non-printable chars from buffer when setting comments
    comments=$(echo "$buff" | cut -d' ' -f2- | tr -cd "[:print:]")
  fi
  if [[ "$comments" == *"skcc"* ]]; then
        skcc=$(awk -F 'skcc' '{print $2}' <<< "$comments")
	skcc=$(echo "$skcc" | tr -d ' ')
  else
    skcc=""
  fi
  if [[ ! -z "$contestname" ]]
  then
    comments="$comments - $contestname"
  fi
  debug "$comments"

  if [ ! -z "$freq" ]
  then
    mhz=$(bc <<< "scale = 4; ($khz/1000000)")
  fi

  echo "<CALL:${#dxcall}>$dxcall" | tr '[:lower:]' '[:upper:]' >> "$logfile"
  echo "   <BAND:${#band}>$band" | tr '[:lower:]' '[:upper:]' >> "$logfile"
  echo "   <FREQ:${#mhz}>$mhz" | tr '[:lower:]' '[:upper:]' >> "$logfile"
  echo "   <MODE:${#mode}>$mode" | tr '[:lower:]' '[:upper:]' >> "$logfile"
  echo "   <QSO_DATE:${#date}>$date" | tr '[:lower:]' '[:upper:]' >> "$logfile"
  echo "   <TIME_ON:${#timeon}>$timeon" | tr '[:lower:]' '[:upper:]' >> "$logfile"
  echo "   <STATION_CALLSIGN:${#station_call}>$station_call" | tr '[:lower:]' '[:upper:]' >> "$logfile"
  echo "   <OPERATOR:${#decall}>$decall" | tr '[:lower:]' '[:upper:]' >> "$logfile"
  echo "   <RST_SENT:${#sentrs}>$sentrs" | tr '[:lower:]' '[:upper:]' >> "$logfile"
  echo "   <RST_RCVD:${#recvrs}>$recvrs" | tr '[:lower:]' '[:upper:]' >> "$logfile"
  echo "   <COMMENT:${#comments}>$comments" | tr '[:lower:]' '[:upper:]' >> "$logfile"
  if [ ! -z "$skcc" ] && [ ! -z "$myskcc" ]
  then
      echo "   <SKCC:${#skcc}>$skcc" | tr '[:lower:]' '[:upper:]' >> "$logfile"
      echo "   <MY_SKCC:${#myskcc}>$myskcc" | tr '[:lower:]' '[:upper:]' >> "$logfile"
  fi
  echo "<EOR>" | tr '[:lower:]' '[:upper:]' >> "$logfile"
  qsocount="$(($qsocount+1))"
  serial="$(($serial+1))"
  echo "QSO $qsocount" > "./.loginfo-$contestname"
  echo "SERIAL $serial" >> "./.loginfo-$contestname"
  dupe="false"
  lastaction="Logged $buff"
  drawlastaction
  clearbuff
  menu
}

send_tu_exchange_logqso() {
  debug "${FUNCNAME[0]}"
  update_exchange
  cwsend "TU $temp_exchange"
  logqso
  clearbuff
}

send_tu_serial_exchange_logqso() {
  debug "${FUNCNAME[0]}"
  update_exchange
  cwsend "TU $serial $temp_exchange"
  logqso
  clearbuff
}

send_call_exchange() {
  debug "${FUNCNAME[0]}"
  update_exchange
  local call=$(getcall)
  cwsend "$call $temp_exchange"
}

send_serial() {
  cwsend "$serial"
}

send_tu_logqso_cq() {
  debug "${FUNCNAME[0]}"
  cwsend "TU $mycq"
  logqso
  clearbuff
}

send_tu_logqso_mycall() {
  debug "${FUNCNAME[0]}"
  cwsend "TU $mycall"
  logqso
  clearbuff
}

send_tu_e1_logqso_cq() {
  debug "${FUNCNAME[0]}"
  local e1=$(gete1)
  cwsend "TU $e1 $mycq"
  logqso
  clearbuff
}

# switch between run and s&p
toggle_run() {
  debug "${FUNCNAME[0]}"
  if [[ "$logmode" == "run" ]]
  then
    logmode="sandp"
  else
    logmode="run"
  fi
  clearbuff
  menu
}

# cycle through the list of modes available
cycle_modes() {
  debug "${FUNCNAME[0]}"
  max_mode_index=${#modes[@]}
  max_mode_index=$((max_mode_index-1))
  if [ "$mode_index" == "$max_mode_index" ]
  then
    mode_index=0
  else
    mode_index=$((mode_index+1))
  fi
  mode="${modes[$mode_index]}"
  clearbuff
  menu
}

setband() {
  if [ "$userig" == "true" ]
  then
    # only lookup frequency and band information once per call
    if [ "$checked_band_for_current_call" == "false" ]
    then
      getfreq
      khz="$freq"
      getband "$freq"
    fi
  fi
}

# arg1 is call to check
checkdupe() {
  debug "${FUNCNAME[0]}"
  if fgrep -qiF "$1" "$logfile"
  then
    if [ "$userig" == "true" ]
    then
      worked_bands=$(grep -iA3 "$1" "$logfile" | grep "BAND" | cut -d'>' -f2)
      worked=$(echo "$worked_bands" | grep "$band")
      if [ -z $worked ]
      then
        echo "false"
      else
        echo "true"
      fi
    else
      echo "true"
    fi
  else
    echo "false"
  fi
}

#
# ------------ functions for special key bindings ---------------
#              enter, tab, backspace, escape, space
#
runcommand() {
  debug "${FUNCNAME[0]}"
  local prefix=$(echo "$1" | cut -d' ' -f1)
  if [[ "$prefix" == ":rig" ]]
  then
    local rigargs=$(echo "$1" | cut -d' ' -f2-)
    rigcommand "$rigargs"
    subbuff="$rigres"
    drawsubmenu
  else
    case "$prefix" in
    ":quit") echo "" && exit ;;
    ":serial") setserial $(echo "$1" | cut -d' ' -f2) ;;
    ":qrs") qrs ;;
    ":qrq") qrq ;;
    ":freq") setfreq $(echo "$1" | cut -d' ' -f2) ;;
    ":lotw") lotw_upload ;;
    ":wpm")  setwpm $(echo "$1" | cut -d' ' -f2) ;;
    *) buff="unknown command $prefix" && drawbuff ;;
    esac
  fi
}

rigcommand() {
  debug "${FUNCNAME[0]}"
  rigctlcount=0
  if [[ "$userig"  == "true" ]]
  then
    local arg1=$(echo "$1" | cut -d' ' -f1)
    #CW string might have spaces, and quotes don't pass correctly
    #so they are treated specially
    if [[ "$arg1" == "b" ]]  #Sending CW
    then
      debug "Sending CW..."
      local send1=$(echo "$1" | sed 's/^b\ //g' | sed "s/'//g")
      debug "$rigctl $rigoptions -m $rig -r $rigdevice b '$send1'"
      for rigctlcount in {1..5} #try rigctl several times in case radio is busy.
      do
        $($rigctl $rigoptions -m $rig -r $rigdevice b "$send1") && break
	sleep 0.1
      done 
    else #Anything but sending CW
      local send1=$(echo "$1" | sed "s/'//g")
      debug "$rigctl $rigoptions -m $rig -r $rigdevice $send1"
      for rigctlcount in {1..5} #try rigctl several times in case radio is busy
      do
        rigres=$($rigctl $rigoptions -m $rig -r $rigdevice $send1) && break
	sleep 0.1
      done
    fi
    debug "Rig command returned: $rigres; required attempts: $rigctlcount"
    if [[ "$keywithhamlib" != "true" ]]; then openkey; fi
    if [[ "$arg1" == "F" ]]
    then
      freq="$rigres"
      drawstatus
    fi
    if [[ "$arg1" == "l" ]]
    then
      speed="$rigres"
      drawstatus
    fi
  fi
}
# arg1 is serial
setserial() {
  debug "${FUNCNAME[0]}"
  serial=$1
  drawstatus
}

# arg1 is frequency
setfreq() {
  debug "${FUNCNAME[0]}"
  rigcommand "F $1"
  freq=$1
  drawstatus
}

getfreq() {
  debug "${FUNCNAME[0]}"
  rigcommand "f"
  freq=$(tr -dc '[[:print:]]' <<< "$rigres")
  freq=$(echo "$freq" | sed 's/[^0-9]*//g')
}

getkeyerspeed() {
  if [[ "$keywithhamlib" == "true" ]]
  then
    rigcommand 'l KEYSPD'
    debug "keyer is now $speed wpm"
  fi
}

getband() {
  declare -A regex_array
  regex_array=( ['6M']='^50[0-9]*$' ['10M']='^28[0-9]*$' ['12M']='^24[0-9]*$' ['15M']='^21[0-9]*$' ['17M']='^18[0-9]*$' ['20M']='^14[0-9]*$' ['30M']='^10[0-9]*$' ['40M']='^7[0-9]*$' ['80M']='^35[0-9]*$' )

  for k in "${!regex_array[@]}"
  do
    if [[ $freq =~ ${regex_array[$k]} ]]
    then
      band=$k
      break
    fi
  done
}


# in both modes, enter simply sends what is in the buffer
enter() {
  debug "${FUNCNAME[0]}"
  if [[ "${buff:0:1}" == ":" ]]
  then
    runcommand "$buff"
  else
    sendbuff
  fi
}
runenter=enter
sandpenter=enter

# kills any current keyer process to halt transmission
escape() {
  debug "${FUNCNAME[0]}"
  pid=""
  pid=$(pgrep -f "$keyer")
  if [[ ! -z $pid ]]
  then
    kill -9 $pid
    wait $pid
  fi
  if [[ "$usekeyer"  == "true" ]]
  then
    debug "$1 usekeyer=$usekeyer"
    if [[ "$keywithhamlib" != "true" ]]
    then
      openkey
    else
      rigcommand \stop_morse
    fi
  fi
}
runescape=escape
sandpescape=escape

# auto completes the first column of the callfile if there are multiple matches
# if there is a single match, it pulls the exchange portion from the callfile
tab() {
  debug "${FUNCNAME[0]}"
  local callbuff=$(echo "$buff" | tr " " "$delimeter")
  if [[ $(grep -i "$callbuff" "$callfile" | wc -l)  -eq 1 ]]
  then
    # make certain to trim spaces, and any non-printable chars from autocompleted exchange
    local buffexchange=$(grep -i "^$callbuff" "$callfile" | cut -d"$delimeter" -f2- | tr "$delimeter" ' ' | sed -e 's/^[[:space:]]*//' | tr -cd "[:print:]")
    echo "grep -i \"$callbuff\" \"$callfile\" | cut -d\"$delimeter\" -f1)" >> debug
    local call=$(grep -i "$callbuff" "$callfile" | cut -d"$delimeter" -f1)
    buff="$call $buffexchange"
    subbuff=""
    echo "single: $callbuff" >> debug
    drawsubmenu
    drawbuff
    # if the contest file wants a space after for copying serial etc. append it
    if [[ "$appendspace" == "true" ]]
    then
      appendbuff " "
    fi
  else
    subbuff=$(grep -i "^$callbuff" "$callfile" | cut -d"$delimeter" -f1 | tr '\r\n' ' ')
    echo "mult: $callbuff" >> debug
    drawsubmenu
  fi
}
runtab=tab
sandptab=tab

# appends a space to the buffer
space() {
  debug "${FUNCNAME[0]}"
  appendbuff " "
}
runspace=space
sandpspace=space

# remove a char from the buffer
backspace() {
  debug "${FUNCNAME[0]}"

  if [[ ! -z "$buff" ]]
  then
    buff="${buff:0:-1}"
    if [[ "${#buff}" -ge "3" ]]
    then
      local call=$(echo "$buff" | cut -d' ' -f1)
      dupe=$(checkdupe "$call")
    else
      dupe="false"
    fi

    if [[ "$dupe" == "true" ]]
    then
      tput setaf 1
    fi

    tput el1
    tput cup $buffline 0
    echo -n ">$buff"
    tput sgr0
  fi
  setbuffcursor
}
runback="backspace"
sandpback="backspace"

#
# ------------ drawing routines ---------------
#

# draw the main menu screen and calculate buffline
menu() {
  debug "${FUNCNAME[0]}"
  clearscreen
  tput cup $menuline 0
  buffline=0
  drawstatus
  drawlastaction
  # build the function map for the menu
  for i in {1..9}
  do
    f="f$i"
    func="$logmode$f"
    if [ -n "$(type -t ${!func})" ] && [ "$(type -t ${!func})" = function ]
    then
      let buffline+=1
      echo -e "$f: ${!func}"
    fi
  done
  let buffline+=2
  drawsubmenu
  drawbuff
}


# takes a single argument of the line number to clear
clearline() {
  debug "${FUNCNAME[0]}"
  tput cup $1 0
  tput el
}

drawlastaction() {
  debug "${FUNCNAME[0]}"
  tput sc
  clearline $lastactionline
  tput dim
  echo "Last action: $lastaction"
  tput sgr0
  tput rc
}

# takes a single argument of the text to append to buff
appendbuff() {
  debug "${FUNCNAME[0]}"
  buff="$buff$1"
  tput el1

  if [[ "${#buff}" -ge "3" ]]
  then
    local call=$(echo "$buff" | cut -d' ' -f1)
    dupe=$(checkdupe "$call")
  fi

  if [[ "$dupe" == "true" ]]
  then
    tput setaf 1
  fi
  tput cup $buffline 0
  echo -n ">$buff"
  tput sgr0
  setbuffcursor
}

clearbuff() {
  debug "${FUNCNAME[0]}"
  buff=""
  drawbuff
}

clearscreen() {
  debug "${FUNCNAME[0]}"
  tput clear
}

drawbuff() {
  debug "${FUNCNAME[0]}"
  clearline $buffline
  tput cup $buffline 0
  echo -n ">$buff"
  tput sgr0
  setbuffcursor
}

drawstatus() {
  debug "${FUNCNAME[0]}"
  prev_status=$status
  if [[ $(type -t get_mults) == "function" ]]
  then
    get_mults
    status="Mode: $mode $logmode  Speed: $speed Freq: $freq Call: $mycall QSO: $qsocount Serial: $serial Mults: $mults"
  else
    status="Mode: $mode $logmode  Speed: $speed Freq: $freq Call: $mycall QSO: $qsocount Serial: $serial"
  fi
  #Only update the status bar/fifo if it has changed 
  if [[ $status != $prev_status ]]
  then
    #Display status bar if it's enabled:
    if [[ $statusbar != "false" ]]
    then
      tput sc
      clearline $statusline
      tput bold
      echo "$status"
      tput sgr0
      tput rc
    fi

    #If FIFO is enabled, write status values to files
    if [[ "$fifo" == "true" ]] 
    then
      echo "$mode" > "$folder/mode"
      echo "$logmode" > "$folder/logmode"
      echo "$speed" > "$folder/speed"
      echo "$freq" > "$folder/freq"
      echo "$mycall" > "$folder/mycall"
      echo "$qsocount" > "$folder/qsocount"
      echo "$serial" > "$folder/serial"
      echo "$status" > "$folder/statusbar"
    fi
  fi
}

drawsubmenu() {
  debug "${FUNCNAME[0]}"
  tput sc
  let subline=$buffline+2
  tput cup $subline 0
  tput ed
  echo $subbuff
  tput rc
}

setbuffcursor() {
  debug "${FUNCNAME[0]}"
  tput cup $buffline $((${#buff}+1))
}
#
# ------------ main loop and script init ---------------
#

mainloop() {
  #redirect all stderr to dev null - this supressis killed pid messages etc.
  exec 2>/dev/null
  debug "${FUNCNAME[0]}"
  debug "my pid $BASHPID"
  debug "logfile: $logfile"
  if [ ! -f "$logfile" ]; then
    debug "no log found clearing loginfo"
    #remove loginfo file if no current log is found
    debug "removing ./.loginfo-$contestname"
    rm "./.loginfo-$contest"
    debug "creating logfile: $logfile"
    touch "$logfile"
    echo "<ADIF_VER:4>1.00" >> "$logfile"
    echo "<EOH>" >> "$logfile"
  fi
  #Create or remove fifo folder if enabled
  if [[ "$fifo" == "true" ]] 
  then
    if [[ ! -d "$folder" ]]; then
      mkdir "$folder"
    fi
  else
    #Note the fifo folders are not deleted at
    #shutdown to avoid breaking tmux bars.
    #Delete it if it has been explicitly disabled.
    rm -rf "$folder"
  fi
  band=""
  freq=""
  if [ "$userig" == "true" ]
  then
    getfreq
    getkeyerspeed
  fi
  khz="$freq"
  getband "$freq"
  buff=""
  subbuff=""
  lastaction=""
  dupe="false"

  if [[ $statusbar == "true" ]]; then
    loc=1
  else
    loc=0
  fi
  statusline=0
  lastactionline=$((0 + loc))
  menuline=$((1 + loc)) 

  cqpid=""
  temp_exchange="$myexchange"
  if [ "$config_version" != "$clogger_version" ]
  then
    subbuff="WARNING - Mismatched configuration version"
    drawsubmenu
    drawbuff
  fi
  if [ "$userig" == "false" & "$keywithrig" == "true " ]
  then
    subbuff="WARNING - Mismatched userig and keywithrig configuration"
    drawsubmenu
    drawbuff
  fi
  menu
  while true
  do
    key=$(readkey)
    mappedkey=$(mapkey "$key")
    killcqpid
    execfunc "$mappedkey" "$logmode"
  done
}


# we MUST initialize our keycodes
initkeys
qsocount=0
serial=1
#set serial and log count based on loginfo
if test -f "./.loginfo-$contestname"; then
  debug "getting qso count and serial from loginfo"
  qsocount=$(grep QSO ".loginfo-$contestname" | cut -d' ' -f2)
  serial=$(grep SERIAL ".loginfo-$contestname" | cut -d' ' -f2)
fi
# if we had a bogus loginfo, reset qso and serial counts
if [ "$qsocount" == "" ]
then
 qsocount=0
 serial=1
fi
# call our main loop
mainloop
