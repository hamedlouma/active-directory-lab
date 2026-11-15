<#
    Audit-Projet1.ps1 - Etat des lieux de ce projet (Active Directory howl.local)
    A lancer sur DC01, dans PowerShell en administrateur :
        powershell -ExecutionPolicy Bypass -File .\Audit-Projet1.ps1
    Resultats : affiches a l'ecran + enregistres dans C:\Audit-Projet1\
#>

$out = "C:\Audit-Projet1"
New-Item -ItemType Directory -Path $out -Force | Out-Null
Start-Transcript -Path "$out\audit.txt" -Force | Out-Null

function Section($titre, [scriptblock]$bloc) {
    Write-Host "`n==================== $titre ====================" -ForegroundColor Cyan
    try { & $bloc | Out-Host } catch { Write-Host "ERREUR : $($_.Exception.Message)" -ForegroundColor Red }
}

Import-Module ActiveDirectory, GroupPolicy, DnsServer, DhcpServer -ErrorAction SilentlyContinue

Section "1. Domaine et foret" {
    Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode, PDCEmulator
    Get-ADForest | Select-Object Name, ForestMode, GlobalCatalogs
}

Section "2. Services essentiels du DC" {
    Get-Service adws, kdc, netlogon, dns, dhcpserver, ntds | Select-Object Name, Status, StartType
}

Section "3. Configuration reseau de DC01" {
    Get-NetIPConfiguration | Select-Object InterfaceAlias,
        @{n='IPv4';e={$_.IPv4Address.IPAddress}},
        @{n='Passerelle';e={$_.IPv4DefaultGateway.NextHop}},
        @{n='DNS';e={$_.DNSServer.ServerAddresses -join ', '}}
    Get-NetIPInterface -AddressFamily IPv4 | Where-Object Dhcp -eq 'Enabled' |
        Select-Object InterfaceAlias, Dhcp
}

Section "4. DNS - zones et enregistrements" {
    Get-DnsServerZone | Select-Object ZoneName, ZoneType, IsDsIntegrated, IsReverseLookupZone
    Get-DnsServerResourceRecord -ZoneName (Get-ADDomain).DNSRoot -RRType A |
        Select-Object HostName, @{n='IP';e={$_.RecordData.IPv4Address}}
    Get-DnsServerForwarder | Select-Object IPAddress
}

Section "5. DHCP - autorisation, etendues, options, exclusions, baux" {
    Get-DhcpServerInDC
    Get-DhcpServerv4Scope | Select-Object ScopeId, Name, StartRange, EndRange, SubnetMask, State, LeaseDuration
    foreach ($s in Get-DhcpServerv4Scope) {
        Write-Host "-- Options de l'etendue $($s.ScopeId)"
        Get-DhcpServerv4OptionValue -ScopeId $s.ScopeId | Select-Object OptionId, Name, Value
        Get-DhcpServerv4OptionValue | Select-Object OptionId, Name, Value
        Write-Host "-- Exclusions"
        Get-DhcpServerv4ExclusionRange -ScopeId $s.ScopeId
        Write-Host "-- Reservations"
        Get-DhcpServerv4Reservation -ScopeId $s.ScopeId | Select-Object IPAddress, Name, ClientId
        Write-Host "-- Baux actifs"
        Get-DhcpServerv4Lease -ScopeId $s.ScopeId | Select-Object IPAddress, HostName, AddressState, LeaseExpiryTime
    }
}

Section "6. Unites d'organisation (OU)" {
    Get-ADOrganizationalUnit -Filter * -Properties ProtectedFromAccidentalDeletion |
        Select-Object Name, DistinguishedName, ProtectedFromAccidentalDeletion
}

Section "7. Utilisateurs du domaine" {
    Get-ADUser -Filter * -Properties Enabled, PasswordNeverExpires, DoesNotRequirePreAuth, ServicePrincipalName, LastLogonDate, MemberOf |
        Select-Object SamAccountName, Enabled, PasswordNeverExpires,
            @{n='PreAuthDesactivee(ASREP)';e={$_.DoesNotRequirePreAuth}},
            @{n='SPN(Kerberoast)';e={$_.ServicePrincipalName -join ', '}},
            LastLogonDate,
            @{n='OU';e={($_.DistinguishedName -split ',',2)[1]}} |
        Format-Table -AutoSize
}

Section "8. Groupes et membres" {
    Get-ADGroup -Filter 'Name -like "GRP_*"' | ForEach-Object {
        Write-Host "-- $($_.Name)"
        Get-ADGroupMember $_ | Select-Object SamAccountName, objectClass
    }
    Write-Host "-- Admins du domaine"
    Get-ADGroupMember "Domain Admins" -ErrorAction SilentlyContinue | Select-Object SamAccountName
    Get-ADGroupMember "Admins du domaine" -ErrorAction SilentlyContinue | Select-Object SamAccountName
}

Section "9. Ordinateurs du domaine" {
    Get-ADComputer -Filter * -Properties OperatingSystem, IPv4Address, LastLogonDate |
        Select-Object Name, OperatingSystem, IPv4Address, LastLogonDate,
            @{n='OU';e={($_.DistinguishedName -split ',',2)[1]}} | Format-Table -AutoSize
}

Section "10. Politique de mot de passe et verrouillage" {
    Get-ADDefaultDomainPasswordPolicy | Select-Object MinPasswordLength, PasswordHistoryCount,
        MaxPasswordAge, MinPasswordAge, ComplexityEnabled, LockoutThreshold, LockoutDuration, LockoutObservationWindow
}

Section "11. GPO et liaisons" {
    Get-GPO -All | Select-Object DisplayName, GpoStatus, CreationTime, ModificationTime | Format-Table -AutoSize
    $cibles = @((Get-ADDomain).DistinguishedName) + (Get-ADOrganizationalUnit -Filter *).DistinguishedName
    foreach ($c in $cibles) {
        $liens = (Get-GPInheritance -Target $c).GpoLinks
        if ($liens) { Write-Host "-- $c"; $liens | Select-Object DisplayName, Enabled, Enforced, Order }
    }
    Get-GPOReport -All -ReportType Html -Path "$out\Rapport-GPO.html"
    Write-Host "Rapport HTML de toutes les GPO : $out\Rapport-GPO.html" -ForegroundColor Green
}

Section "12. Partages reseau et permissions" {
    Get-SmbShare | Where-Object { $_.Name -notmatch '\$$' } | ForEach-Object {
        Write-Host "-- \\$env:COMPUTERNAME\$($_.Name)  ($($_.Path))"
        Get-SmbShareAccess -Name $_.Name | Select-Object AccountName, AccessControlType, AccessRight
        (Get-Acl $_.Path).Access | Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited
    }
    # Droits NTFS des sous-dossiers de C:\Partage (cloisonnement IT / RH / confidentiel / commun)
    Get-ChildItem "C:\Partage" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $acl = Get-Acl $_.FullName
        Write-Host "-- $($_.FullName)  (heritage coupe : $($acl.AreAccessRulesProtected))"
        $acl.Access | Where-Object { $_.FileSystemRights -notmatch '^-?\d+$' } |
            Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited
    }
}

Section "13. Diagnostic AD (dcdiag, erreurs uniquement)" {
    $diag = dcdiag /q
    if ($diag) {
        $diag
        Write-Host "=> dcdiag a remonte des erreurs (voir ci-dessus)" -ForegroundColor Yellow
    } else {
        Write-Host "=> Aucun probleme detecte par dcdiag" -ForegroundColor Green
    }
}

Stop-Transcript | Out-Null
Write-Host "`nAudit termine. Fichiers dans $out" -ForegroundColor Green
