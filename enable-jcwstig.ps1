#enable-esxstig.ps1
#requires -psedition desktop
#requires -runasadministrator

[CmdletBinding()]
param (
  [string[]]$esxlist
  , [string[]]$clustername
  , $cred
  , [string[]]$to
  , [string]$from
  , [string]$smtp
  , [string]$syslogserver
  , [string[]]$vclist

)

begin {

  connect-viserver $vclist -force
  ## Prep
  if (-not($cred)) {
    $cred = Get-Credential -Username 'root' -Message 'root pwd'
  }

  # if ($clustername) {
  #   $esxlist = get-cluster $clustername | get-vmhost | select -ExpandProperty name
  # }
  ## Functions
  function send-notification {

    param (
      [string[]]$objectname
      , [string[]]$actionname
      , [string]$parentname = $parentname
    )

    $hostname = $env:COMPUTERNAME
    $scriptname = $MyInvocation.ScriptName
    [string]$message = "$parentname`: $objectname`: $actionname"

    $body = @"
$message

Notification Source:
$hostname
$scriptname
"@

    $smtpparam = @{
      to         = $to
      from       = $from
      subject    = $message
      body       = $body
      smtpserver = $smtp
    }

    send-mailmessage @smtpparam



    $syslogparam = @{
      Server          = $syslogserver
      message         = $message
      Severity        = "Informational"
      Facility        = "local0"
      ApplicationName = "$scriptname [jcw]"
    }

    Send-SyslogMessage @syslogparam

    write-verbose $message
  }

  function disable-sshd {
    send-notification -actionname 'Disabling ssh' -objectname $vmh.name
    #ESXI-65-000035
    #ESXI-65-100035
    #ESXI-65-200035
    #Disable SSH
    $sshd = $vmh | Get-VMHostService | ? { $_.key -eq 'TSM-SSH' }
    Set-VMHostService -HostService $sshd -Policy Off
    $sshd | Stop-VMHostService -Confirm:$false

    #ESXI-65-000036
    #Disable esx shell
    $tsm = $vmh | get-vmhostservice | ? { $_.key -eq 'TSM' }
    Set-VMHostService -HostService $tsm -Policy Off
    $tsm | Stop-VMHostService -Confirm:$false

  }

  function enable-sshd {

    send-notification 'Enabling ssh' -objectname $vmh.name

    $sshd = $vmh | Get-VMHostService | ? { $_.key -eq 'TSM-SSH' }
    Start-VMHostService -Confirm:$false -HostService $sshd

    $tsm = $vmh | get-vmhostservice | ? { $_.key -eq 'TSM' }
    $tsm | Start-VMHostService -Confirm:$false
  }

  function config-networksecurity {

    send-notification -actionname 'Configuring network security settings' -objectname $vmh.name

    # CAT01
    ## ESXI-65-000060
    ## switch & portgroupdisable mac address changes
    # CAT02
    ## ESXI-65-000059
    ## switch & portgroup: disable forged transmits
    ## ESXI-65-000061
    ## switch & portgroup: disable promiscuous mode

    $vswlist = $vmh | Get-VirtualSwitch
    foreach ($vsw in $vswlist) {
      $vswpolicy = $vsw | Get-SecurityPolicy

      $vswsecpolarg = @{
        macchanges          = $false
        forgedtransmits     = $false
        allowpromiscuous    = $false
        virtualswitchpolicy = $vswpolicy
      }

      Set-SecurityPolicy @vswsecpolarg
    }

    $vpglist = $vmh | Get-VirtualPortGroup
    foreach ($vpg in $vpglist) {
      $vpgpolicy = $vpg | Get-SecurityPolicy

      $vpgsecpolarg = @{
        macchanges             = $false
        forgedtransmits        = $false
        allowpromiscuous       = $false
        virtualportgrouppolicy = $vpgpolicy
      }

      Set-SecurityPolicy @vpgsecpolarg


      # $vpg | Get-SecurityPolicy | Set-SecurityPolicy -MacChanges $false -ForgedTransmits $false
    }

  }

  function config-ssh {

    send-notification -actionname 'Configuring ssh settings' -objectname $vmh.name

    if ($sftp = New-SFTPSession -ComputerName $vmh.name -Credential $cred -AcceptKey) {
      #upload /etc/issue
      # ESXI-65-000008
      Set-SFTPFile -SFTPSession $sftp -LocalFile ./issue -RemotePath /etc -Overwrite

      #upload /etc/ssh/sshd_config
      #ESXI-65-000011
      #ESXI-65-000017
      #ESXI-65-000009
      #ESXI-65-000012
      #ESXI-65-000013
      #ESXI-65-000015
      #ESXI-65-000016
      #ESXI-65-000020
      #ESXI-65-000021
      #ESXI-65-000023
      #ESXI-65-000024
      #ESXI-65-000025
      #ESXI-65-000028
      Set-SFTPFile -SFTPSession $sftp -LocalFile ./sshd_config -RemotePath /etc/ssh -Overwrite
    }
    else {
      write-host "Script Error: Cannot connect to esx via ssh"
      break
    }
  }

  function config-acctlockout {

    send-notification -actionname 'Configuring account lockout' -objectname $vmh.name

    #ESXI-65-000005
    # $vmh | Get-AdvancedSetting -name security.accountlockfailures |
    # Set-AdvancedSetting -Value 3 -Confirm:$false

    $setadvarg = @{
      advancedsetting = $vmh | Get-AdvancedSetting -Name Security.AccountLockFailures
      value           = "3"
      confirm         = $false
    }

    Set-AdvancedSetting @setadvarg

    #ESXI-65-000006
    # $vmh | Get-AdvancedSetting -Name security.accountunlocktime |
    # Set-AdvancedSetting -Value 900 -Confirm:$false

    $setadvarg = @{
      advancedsetting = $vmh | Get-AdvancedSetting -Name Security.AccountUnlockTime
      value           = "900"
      confirm         = $false
    }

    Set-AdvancedSetting @setadvarg
  }

  function config-welcomemessage {

    send-notification -actionname 'Configuring welcome message' -objectname $vmh.name

    #ESXI-65-100007

    $welcomemessage = @"

This system is for the use of authorized users only.
Individuals using this computer system without
authority or in excess of their authority are subject
to having all of their activities on this system
monitored and recorded by system personnel. Anyone
using this system expressly consents to such
monitoring and is advised that if such monitoring
reveals possible evidence of criminal activity
system personnel may provide the evidence of such
monitoring to law enforcement officials.

"@

    $vmh | Get-AdvancedSetting -Name Annotations.WelcomeMessage |
    Set-AdvancedSetting -Value $welcomemessage -Confirm:$false


  }

  function config-paswordrequirements {

    send-notification -actionname 'Configuring password requirements' -objectname $vmh.name

    #ESXI-65-000031
    #ESXI-65-100031
    #ESXI-65-200031
    #ESXI-65-300031
    #ESXI-65-400031
    #ESXI-65-500031

    $setadvarg = @{
      advancedsetting = $vmh | Get-AdvancedSetting -Name Security.PasswordQualityControl
      value           = "similar=deny retry=3 min=disabled,disabled,disabled,disabled,15"
      confirm         = $false
    }

    Set-AdvancedSetting @setadvarg

    #ESXI-65-000032
    #/etc/pam.d/passwd should be
    # password   sufficient   /lib/security/$ISA/pam_unix.so use_authtok nullok shadow sha512 remember=5


    $sshsession = New-SSHSession -Credential $cred -ComputerName $vmh.name
    $pamdpasswd = (Invoke-SSHCommand -SSHSession $sshsession -command 'cat /etc/pam.d/passwd').output
    $targetpattern = "^password\s\+sufficient\s\+/lib/security/$ISA/pam_unix.so use_authtok nullok shadow sha512 remember=5$"
    #$replacepattern = "^password\s\+sufficient\s\+/lib"

    if (-not($pamdpasswd -match $targetpattern)) {
      $date = (get-date -f s ) -replace ':', ''
      $sedcommand = "sed -i.bak 's|^password\s\+suff.*|password   sufficient   /lib/security/`$ISA/pam_unix.so use_authtok nullok shadow sha512 remember=5|g' /etc/pam.d/passwd"
      Invoke-SSHCommand -sshsession $sshsession -Command $sedcommand
    }
  }

  function config-miscellaneousitems {

    send-notification -actionname 'Configuring miscellaneous requirements' -objectname $vmh.name

    #ESXI-65-000034
    #Disable Managed Object Browser

    $setadvarg = @{
      advancedsetting = $vmh | Get-AdvancedSetting -Name Config.HostAgent.plugins.solo.enableMob
      value           = "false"
      confirm         = $false
    }

    Set-AdvancedSetting @setadvarg

    #ESXI-65-000062
    #disable dvfilter network api
    $setadvarg = @{
      advancedsetting = $vmh | Get-AdvancedSetting -Name Net.DVFilterBindIpAddress
      value           = ""
      confirm         = $false
    }

    Set-AdvancedSetting @setadvarg

  }

  function config-connectiontimeouts {

    send-notification -actionname 'Configuring connection timeouts' -objectname $vmh.name

    #ESXI-65-000041
    #ESXI-65-100041
    #set host timeout to 10 minutes

    $setadvarg = @{
      advancedsetting = $vmh | Get-AdvancedSetting -Name UserVars.ESXiShellInteractiveTimeOut
      value           = "600"
      confirm         = $false
    }

    Set-AdvancedSetting @setadvarg

    #ESXI-65-000042
    #ESXI-65-100042
    #terminat shell services after 10 min

    $setadvarg = @{
      advancedsetting = $vmh | Get-AdvancedSetting -Name UserVars.ESXiShellTimeOut
      value           = "600"
      confirm         = $false
    }

    Set-AdvancedSetting @setadvarg

    #ESXI-65-000043
    #ESXI-65-100043
    #logout of console after 10 min

    $setadvarg = @{
      advancedsetting = $vmh | Get-AdvancedSetting -Name UserVars.DcuiTimeOut
      value           = "600"
      confirm         = $false
    }

    Set-AdvancedSetting @setadvarg

  }

  function config-persistentscratch {

    send-notification -actionname 'Configuring persistent scratch' -objectname $vmh.name

    #$esxcli = get-esxcli -VMHost $vmh -V2
    $adv = 'ScratchConfig.ConfiguredScratchLocation'
    if ($ds = $vmh | gds *scratch*) {
      $psdrivename = 'ds'
      New-PSDrive -name $psdrivename -Root \ -PSProvider VimDatastore -Datastore $ds

      $path1 = '/vmfs/volumes'
      $path2 = $ds.name + "/"
      $path3 = ".locker-$($vmh.name)"

      $path = join-path -path $path1 -ChildPath $path2 |
      join-path -ChildPath $path3 #|

      $path = $path.replace('\', '/')

      $setadvparam = @{
        advancedsetting = $vmh | Get-AdvancedSetting -Name $adv
        value           = $path
        confirm         = $false
      }

      new-item -ItemType Directory -Name $path3 -Path "$($psdrivename)`:"
      Set-AdvancedSetting @setadvparam
      get-psdrive $psdrivename | remove-psdrive

    }
    else {
      write-host "no scratch datastore found" #; return
    }
  }

  function restart-esxhost {
    send-notification -actionname 'restarting' -objectname $vmh.name
    restart-vmhost $vmh -confirm:$false
    do { sleep -s 31; $vmh = get-vmhost $vmh; $vmh | select name, ConnectionState } until ($vmh.ConnectionState -match 'disc|notrespond')
    #echo "not disconnected"
    do { sleep -s 31; $vmh = get-vmhost $vmh; $vmh | select name, ConnectionState } until ($vmh.ConnectionState -match 'maintenance')
    #write-verbose "exiting maintenance"
    send-notification -actionname 'exiting maintenance mode' -objectname $vmh.name
    set-vmhost $vmh -state connected
    do { sleep -s 31; $vmh = get-vmhost $vmh; $vmh | select name, ConnectionState } until ($vmh.ConnectionState -match 'connected')
    send-notification -actionname 'ESX connected, in production' -objectname $vmh.name

  }

  function set-esxmaintenancemode {
    if ($vmh.ConnectionState -notmatch 'maint') {

      send-notification -actionname 'Setting maintenance mode' -objectname $vmh.name

      set-vmhost $vmh -state Maintenance
      do { sleep -s 11; $vmh = get-vmhost $vmh } until ($vmh.ConnectionState -match 'maint')
    }
  }


}

process {

  # if ($clustername) {$objectname = (get-cluster $clustername).name}
  # else { $objectname = $esxlist }
  # send-notification -actionname 'Start: Configuring esx stig' -objectname $objectname

  foreach ($cluster in $clustername) {
    $cl = get-cluster $clustername
    $vmhlist = $cl | get-vmhost | sort-object name

    $parentname = $cl.name
    send-notification -actionname 'Start: Configuring ESX STIG' -objectname $cl.name

    foreach ($vmh in $vmhlist ) {

      send-notification -actionname 'Start: Configuring esx stig' -objectname $vmh.name  #-parentname $parentname

      set-esxmaintenancemode

      enable-sshd

      # Apply STIG Items
      config-ssh
      config-networksecurity
      config-acctlockout
      config-connectiontimeouts
      config-welcomemessage
      config-paswordrequirements
      config-miscellaneousitems
      config-persistentscratch

      disable-sshd

      restart-esxhost

      send-notification -actionname 'End: Configuring esx stig' -objectname $vmh.name  #-parentname $parentname
    }
    send-notification -actionname 'End: Configuring esx stig' -objectname $cl.name
  }
}

end {

}