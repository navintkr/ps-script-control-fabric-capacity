<#
.SYNOPSIS
    Verifies reservation status of Microsoft Fabric capacities
.DESCRIPTION
    This script checks all Fabric capacities and their reservation status, then outputs:
    1. Fabric capacities with their Reservation Order IDs and Subscription IDs
    2. Reservation Orders without any capacities tied to them
    3. Fabric capacities without any reservations
#>

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Fabric Capacity Reservation Status Check" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Check if Azure CLI is available
Write-Host "Checking Azure CLI availability..." -ForegroundColor Yellow
$azCliPath = Get-Command az -ErrorAction SilentlyContinue

if (-not $azCliPath) {
    Write-Host "ERROR: Azure CLI (az) not found in PATH." -ForegroundColor Red
    Write-Host "`nPlease ensure Azure CLI is installed and available in your PATH." -ForegroundColor Yellow
    Write-Host "You can:" -ForegroundColor Yellow
    Write-Host "  1. Restart PowerShell after installing Azure CLI" -ForegroundColor Yellow
    Write-Host "  2. Run this script from Command Prompt instead" -ForegroundColor Yellow
    Write-Host "  3. Add Azure CLI to your PATH manually`n" -ForegroundColor Yellow
    
    # Try to find Azure CLI in common installation paths
    $commonPaths = @(
        "${env:ProgramFiles}\Microsoft SDKs\Azure\CLI2\wbin",
        "${env:ProgramFiles(x86)}\Microsoft SDKs\Azure\CLI2\wbin",
        "$env:LOCALAPPDATA\Programs\Microsoft\Azure CLI\wbin"
    )
    
    $foundPath = $null
    foreach ($path in $commonPaths) {
        if (Test-Path "$path\az.cmd") {
            $foundPath = $path
            Write-Host "Found Azure CLI at: $foundPath" -ForegroundColor Green
            $env:PATH = "$foundPath;$env:PATH"
            break
        }
    }
    
    if (-not $foundPath) {
        Write-Host "Could not locate Azure CLI installation." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Azure CLI found. Checking login status..." -ForegroundColor Green

# Check current Azure account
$accountInfo = az account show 2>&1 | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Not logged into Azure CLI. Please run 'az login' first." -ForegroundColor Red
    exit 1
}

# Check if logged in with tenant-level account
if ($accountInfo.id -eq $accountInfo.tenantId) {
    Write-Host "`nWARNING: You are logged in with a tenant-level account." -ForegroundColor Red
    Write-Host "Current Account: $($accountInfo.name)" -ForegroundColor Yellow
    Write-Host "Tenant ID: $($accountInfo.tenantId)" -ForegroundColor Yellow
    Write-Host "`nYou need to set a specific subscription context." -ForegroundColor Yellow
    Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
    
    az account list --query "[].{Name:name, SubscriptionId:id, State:state}" --output table
    
    Write-Host "`nPlease run one of these commands to set your subscription:" -ForegroundColor Yellow
    Write-Host "  az account set --subscription <subscription-id-or-name>" -ForegroundColor White
    Write-Host "`nThen run this script again." -ForegroundColor Yellow
    exit 1
}

Write-Host "Logged in to subscription: $($accountInfo.name)" -ForegroundColor Green
Write-Host "Subscription ID: $($accountInfo.id)`n" -ForegroundColor Green

# Get all Fabric capacities across all subscriptions
Write-Host "Fetching all Fabric capacities..." -ForegroundColor Yellow
$allCapacities = az fabric capacity list 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to retrieve Fabric capacities." -ForegroundColor Red
    Write-Host $allCapacities -ForegroundColor Red
    exit 1
}

$allCapacities = $allCapacities | ConvertFrom-Json

if (-not $allCapacities -or $allCapacities.Count -eq 0) {
    Write-Host "No Fabric capacities found in subscription '$($accountInfo.name)'." -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($allCapacities.Count) Fabric capacity/capacities`n" -ForegroundColor Green

# Separate capacities with and without reservations
$capacitiesWithReservations = @()
$capacitiesWithoutReservations = @()

foreach ($capacity in $allCapacities) {
    # Extract subscription ID from the resource ID
    if ($capacity.id -match '/subscriptions/([^/]+)/') {
        $subscriptionId = $Matches[1]
    } else {
        $subscriptionId = "Unknown"
    }
    
    $capacityInfo = [PSCustomObject]@{
        Name = $capacity.name
        Location = $capacity.location
        ResourceGroup = $capacity.resourceGroup
        SubscriptionId = $subscriptionId
        SKU = $capacity.sku.name
        State = $capacity.state
        ReservationId = $capacity.properties.reservationId
    }
    
    if ($capacity.properties.reservationId) {
        $capacitiesWithReservations += $capacityInfo
    } else {
        $capacitiesWithoutReservations += $capacityInfo
    }
}

# Output 1: Fabric capacities with Reservation Order IDs and Subscription IDs
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "1. FABRIC CAPACITIES WITH RESERVATIONS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($capacitiesWithReservations.Count -gt 0) {
    $capacitiesWithReservations | Format-Table -Property Name, Location, SKU, SubscriptionId, ReservationId -AutoSize
    Write-Host "Total capacities with reservations: $($capacitiesWithReservations.Count)" -ForegroundColor Green
} else {
    Write-Host "No Fabric capacities found with reservations.`n" -ForegroundColor Yellow
}

# Output 2: Reservation Orders without capacities tied to them
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "2. RESERVATIONS WITHOUT FABRIC CAPACITIES" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "Fetching reservation orders..." -ForegroundColor Yellow

# Try to get reservation orders (this may fail due to permissions)
$reservationOrders = $null
try {
    $reservationOrdersJson = az reservations reservation-order list 2>&1
    if ($LASTEXITCODE -eq 0) {
        $reservationOrders = $reservationOrdersJson | ConvertFrom-Json
    } else {
        Write-Host "Unable to retrieve reservation orders. Insufficient permissions." -ForegroundColor Red
        Write-Host "Required permission: Microsoft.Capacity/reservationOrders/read" -ForegroundColor Yellow
        Write-Host "Skipping reservation order check...`n" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Error retrieving reservation orders: $_" -ForegroundColor Red
    Write-Host "Skipping reservation order check...`n" -ForegroundColor Yellow
}

if ($reservationOrders) {
    # Filter for Fabric-related reservations
    $fabricReservations = $reservationOrders | Where-Object { 
        $_.properties.displayName -like "*Fabric*" -or 
        $_.properties.reservedResourceType -eq "Fabric" 
    }
    
    # Get list of reservation IDs that are in use
    $usedReservationIds = $capacitiesWithReservations | ForEach-Object { $_.ReservationId }
    
    # Find reservations not tied to any capacity
    $unusedReservations = @()
    foreach ($reservation in $fabricReservations) {
        # Get individual reservations within the order
        $reservationDetails = az reservations reservation list --reservation-order-id $reservation.name | ConvertFrom-Json
        
        foreach ($detail in $reservationDetails) {
            if ($usedReservationIds -notcontains $detail.id) {
                $unusedReservations += [PSCustomObject]@{
                    ReservationOrderId = $reservation.name
                    ReservationId = $detail.id
                    DisplayName = $reservation.properties.displayName
                    State = $detail.properties.provisioningState
                    Quantity = $detail.properties.quantity
                    SKU = $detail.sku.name
                    ExpiryDate = $reservation.properties.expiryDateTime
                }
            }
        }
    }
    
    if ($unusedReservations.Count -gt 0) {
        $unusedReservations | Format-Table -Property DisplayName, ReservationOrderId, ReservationId, State, Quantity, SKU -AutoSize
        Write-Host "Total unused Fabric reservations: $($unusedReservations.Count)" -ForegroundColor Green
    } else {
        Write-Host "All Fabric reservations are tied to capacities.`n" -ForegroundColor Green
    }
}

# Output 3: Fabric capacities without reservations
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "3. FABRIC CAPACITIES WITHOUT RESERVATIONS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($capacitiesWithoutReservations.Count -gt 0) {
    $capacitiesWithoutReservations | Format-Table -Property Name, Location, ResourceGroup, SubscriptionId, SKU, State -AutoSize
    Write-Host "Total capacities without reservations: $($capacitiesWithoutReservations.Count)" -ForegroundColor Red
    Write-Host "[WARNING] These capacities are using pay-as-you-go pricing!`n" -ForegroundColor Yellow
} else {
    Write-Host "All Fabric capacities have reservations assigned.`n" -ForegroundColor Green
}

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total Fabric Capacities: $($allCapacities.Count)" -ForegroundColor White
Write-Host "  - With Reservations: $($capacitiesWithReservations.Count)" -ForegroundColor Green
Write-Host "  - Without Reservations: $($capacitiesWithoutReservations.Count)" -ForegroundColor $(if ($capacitiesWithoutReservations.Count -gt 0) { "Red" } else { "Green" })

if ($capacitiesWithoutReservations.Count -gt 0) {
    Write-Host "`n[!] Action Required: Consider purchasing reservations for capacities without them to save costs!" -ForegroundColor Yellow
} else {
    Write-Host "`n[OK] All capacities are properly reserved!" -ForegroundColor Green
}
