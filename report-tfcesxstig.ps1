#report-tfcesxstig.ps1

[CmdletBinding()]
param (
  [string[]]$esx
  , [switch]$all
  , $rootcred
  , $csvfile = "./stig.csv"
  , [switch]$full
  , [switch]$exception

)

begin {

  if (!($all) -and !($esx)) {
    write-host 'need an argument: either -all or -esx <esxname>'
    break
  }
  if ($all) {
    $vmhlist = get-vmhost
  }
  if ($esx) {
    $vmhlist = get-vmhost $esx
  }
  if (!($rootcred)) {
    $rootcred = Get-Credential -UserName root -Message 'root password'
  }
  function fullreport {
    $filepath = join-path $env:temp -childpath $("FullStigReport." + (get-date -f s).replace(':', '') + ".xlsx")
    $esxstigreport | sort parent, vmhost, stigid | export-excel -path $filepath
    start excel $filepath
  }

  function exceptionreport {
    $bannerstring = "system is for the use of authorized"
    $filepath = join-path $env:temp -childpath $("ExceptionStigReport." + (get-date -f s).replace(':', '') + ".xlsx")
    $esxstigreport |
    ? { $_.stigtarget -ne $_.stigvalue } |
    ? { !(($_.stigvalue -eq 'null') -and ($null -eq $_.stigtarget)) } |
    # ? { !(($_.stigtarget -match $bannerstring) -and ($stigvalue -match $bannerstring)) } |
    ? { !(($_.stigdescription -eq 'ntp: server configuration') -and ($_.stigtarget -contains $_.stigvalue))} |
    ? { !(($_.stigdescription -eq 'ssh: not running') -and ($_.stigvalue -eq $true))} |
    sort parent, vmhost, stigid | export-excel -path $filepath
    start excel $filepath
    #$global:stigreport = $esxstigreport
  }

  function enable-sshd {
    $sshd = $vmh | Get-VMHostService | ? { $_.key -eq 'TSM-SSH' }
    Start-VMHostService -Confirm:$false -HostService $sshd

    #$tsm = $vmh | get-vmhostservice | ? { $_.key -eq 'TSM' }
    #$tsm | Start-VMHostService -Confirm:$false
  }

  function disable-sshd {
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

  function get-advsetting ($name) {
    (Get-AdvancedSetting -entity $vmh -name $name).value
  }

  function get-sshsetting ($command) {
    (Invoke-SSHCommand $ssh -command $command).output
  }

  function get-powerclisetting ($command) {
    invoke-expression -command $command
  }
}

process {
  $esxstigreport = foreach ($vmh in $vmhlist) {

    enable-sshd | Out-Null
    if ($ssh = New-SSHSession -computername $vmh.name -Credential $rootcred -AcceptKey) {
      #$esxcli = get-esxcli -VMHost $vmh
      $csv = import-csv $csvfile
      foreach ($stig in $csv) {
        #foreach ($stig in $stiglist.keys) {
        #foreach $stigid in
        $stigvalue = $null
        #Clear-Variable -Name "stigvalue"

        #$stigprop = $stiglist[$stig]

        switch ($stig.stigmethod) {
          'advanced' {
            $stigvalue = get-advsetting -name $stig.stigsettingname
          }

          'ssh' {
            $stigvalue = get-sshsetting -command $stig.stigsettingname
          }

          'powercli' {
            $stigvalue = get-powerclisetting -command $stig.stigsettingname
          }

          'n/a' {
            $stigvalue = $stig.stigsettingname
          }

          'esxcli' {
            $esxcli = get-esxcli -VMHost $vmh
            $stigvalue = invoke-expression $stig.stigsettingname
          }

          'manual' {
            $stigvalue = $stig.stigsettingname
          }

        }

        [PSCustomObject]@{
          parent       = $vmh.parent
          vmhost       = $vmh.name
          stigid       = $stig.stigid
          stigcategory = $stig.stigcategory
          stigstatus   = $stig.stigstatus
          stigdescr    = $stig.stigdescr
          stigtarget   = $stig.stigtarget
          stigvalue    = $stigvalue
        }
        #}
      }
      disable-sshd | out-null
    }
    else {
      "$vmh issue with ssh"
    }
  }
}

end {
  if ($full) {fullreport}
  if ($exception) {exceptionreport}
}