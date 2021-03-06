#enable-esxstig.ps1

[CmdletBinding()]
param (
  [string]$esx
  , $cred
  , [string[]]$vclist
)


#$esx = "tfc-esx143"

### Functions ###
function config-networksecurity {
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

#### MAIN ####

## Prep
# if (-not($cred)) {
#   $cred = Get-Credential -Username 'root' -Message 'root pwd'
# }

connect-viserver $vclist -force

if ($vmh = get-vmhost $esx) {
  #$vmhv = $vmh | get-view
  #enable-sshd


  ## Apply STIG Items
  config-networksecurity

}