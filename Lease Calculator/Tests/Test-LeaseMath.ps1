<#
.SYNOPSIS
    Checks the lease math in LeaseMath.ps1 against known-good, hand-checked examples.
.DESCRIPTION
    Plain PowerShell, nothing to install. Run it from anywhere:
        powershell -ExecutionPolicy Bypass -File ".\Lease Calculator\Tests\Test-LeaseMath.ps1"
    Prints PASS/FAIL per check and exits with code 1 if anything failed.
#>

. (Join-Path $PSScriptRoot '..\LeaseMath.ps1')

$script:passed = 0
$script:failed = 0

function Assert-Equal {
    <# .SYNOPSIS Passes if Actual matches Expected (numbers within Tolerance). #>
    param([string]$Name, $Actual, $Expected, [double]$Tolerance = 0.005)
    $ok = if ($Expected -is [double] -or $Expected -is [int] -or $Expected -is [decimal]) {
        $null -ne $Actual -and [math]::Abs([double]$Actual - [double]$Expected) -le $Tolerance
    }
    else { $Actual -eq $Expected }
    if ($ok) { $script:passed++; Write-Host "PASS  $Name" -ForegroundColor Green }
    else { $script:failed++; Write-Host "FAIL  $Name  (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

function Assert-Throws {
    <# .SYNOPSIS Passes if the script block throws an ArgumentException whose message contains MessagePart. #>
    param([string]$Name, [scriptblock]$Code, [string]$MessagePart)
    try {
        & $Code | Out-Null
        $script:failed++; Write-Host "FAIL  $Name  (no error thrown)" -ForegroundColor Red
    }
    catch [System.ArgumentException] {
        if ($_.Exception.Message -like "*$MessagePart*") { $script:passed++; Write-Host "PASS  $Name" -ForegroundColor Green }
        else { $script:failed++; Write-Host "FAIL  $Name  (message was: $($_.Exception.Message))" -ForegroundColor Red }
    }
    catch {
        $script:failed++; Write-Host "FAIL  $Name  (wrong error type: $($_.Exception.GetType().Name))" -ForegroundColor Red
    }
}

# =============================
# FULL LEASE EXAMPLES
# =============================

# Example 1 - the placeholder numbers shown in the app. Worked by hand:
#   Net cap  = 33000 + 895 - 2000 - 1500           = 30395.00
#   Residual = 35000 x 65%                         = 22750.00
#   Deprec.  = (30395 - 22750) / 36                = 212.36
#   Finance  = (30395 + 22750) x 0.0018            = 95.66
#   Base     = 212.3611 + 95.661                   = 308.02
#   Tax      = 308.0221 x 5.9%                     = 18.17
#   Monthly  = 326.20 ; Total = 326.1954 x 36 + 1500 = 13243.03
$ex1 = Get-LeasePayment -CapCost 33000 -Fees 895 -CapReduction 2000 -DownPayment 1500 `
    -ResidualValue (Get-ResidualValue -Msrp 35000 -Percent 65) -MoneyFactor 0.0018 -Term 36 -TaxRatePercent 5.9
Assert-Equal "Example 1: net cap cost"       $ex1.NetCapCost     30395.00
Assert-Equal "Example 1: residual"           $ex1.ResidualValue  22750.00
Assert-Equal "Example 1: depreciation"       $ex1.Depreciation   212.36
Assert-Equal "Example 1: finance charge"     $ex1.FinanceCharge  95.66
Assert-Equal "Example 1: base payment"       $ex1.BasePayment    308.02
Assert-Equal "Example 1: monthly tax"        $ex1.MonthlyTax     18.17
Assert-Equal "Example 1: monthly with tax"   $ex1.MonthlyPayment 326.20
Assert-Equal "Example 1: total lease cost"   $ex1.TotalLeaseCost 13243.03

# Example 2 - round numbers you can do in your head:
#   (30000 - 18000) / 36 = 333.33 ; (30000 + 18000) x 0.0025 = 120.00
#   333.33 + 120 = 453.33 ; x 1.10 = 498.67 ; x 36 = 17952.00
$ex2 = Get-LeasePayment -CapCost 30000 -ResidualValue 18000 -MoneyFactor 0.0025 -Term 36 -TaxRatePercent 10
Assert-Equal "Example 2: depreciation"       $ex2.Depreciation   333.33
Assert-Equal "Example 2: finance charge"     $ex2.FinanceCharge  120.00
Assert-Equal "Example 2: monthly with tax"   $ex2.MonthlyPayment 498.67
Assert-Equal "Example 2: total lease cost"   $ex2.TotalLeaseCost 17952.00

# Example 3 - 0% money factor (promo lease): no finance charge at all
$ex3 = Get-LeasePayment -CapCost 30000 -ResidualValue 18000 -MoneyFactor 0 -Term 24 -TaxRatePercent 0
Assert-Equal "Example 3: 0% finance charge"  $ex3.FinanceCharge  0
Assert-Equal "Example 3: payment = deprec."  $ex3.MonthlyPayment 500.00

# =============================
# APR <-> MONEY FACTOR
# =============================

Assert-Equal "APR 4.32 -> MF 0.0018"         (ConvertTo-MoneyFactor -Apr 4.32)        0.0018 -Tolerance 1e-12
Assert-Equal "MF 0.0018 -> APR 4.32"         (ConvertTo-Apr -MoneyFactor 0.0018)      4.32   -Tolerance 1e-9
Assert-Equal "APR 5 -> MF 0.00208333"        (ConvertTo-MoneyFactor -Apr 5)           0.0020833333 -Tolerance 1e-9
Assert-Equal "APR max matches MF max"        (ConvertTo-MoneyFactor -Apr $LeaseLimits.AprMax) $LeaseLimits.MoneyFactorMax -Tolerance 1e-12
Assert-Equal "MF max is 0.0125"              $LeaseLimits.MoneyFactorMax              0.0125 -Tolerance 1e-12

# =============================
# RESIDUAL $ <-> %
# =============================

Assert-Equal "65% of 35000 = 22750"          (Get-ResidualValue -Msrp 35000 -Percent 65)            22750
Assert-Equal "22750 of 35000 = 65%"          (Get-ResidualPercent -Msrp 35000 -ResidualValue 22750) 65
# The drift case from the review: unrounded round trip lands back on exactly $22,500
$pct = Get-ResidualPercent -Msrp 37345 -ResidualValue 22500
Assert-Equal "Unrounded % round-trips exactly" (Get-ResidualValue -Msrp 37345 -Percent $pct) 22500 -Tolerance 1e-9

# =============================
# READING TYPED NUMBERS
# =============================

Assert-Equal "Reads '`$35,000'"              (ConvertTo-LeaseNumber '$35,000')     35000
Assert-Equal "Reads '5.9%'"                  (ConvertTo-LeaseNumber '5.9%')        5.9
Assert-Equal "Reads ' 1,234.50 '"            (ConvertTo-LeaseNumber ' 1,234.50 ')  1234.5
Assert-Equal "Reads '-0.002' as negative"    (ConvertTo-LeaseNumber '-0.002')      -0.002 -Tolerance 1e-12
Assert-Equal "Blank -> nothing"              ($null -eq (ConvertTo-LeaseNumber ''))     $true
Assert-Equal "'abc' -> nothing"              ($null -eq (ConvertTo-LeaseNumber 'abc'))  $true
Assert-Equal "'1,5OO' (letter O) -> nothing" ($null -eq (ConvertTo-LeaseNumber '1,5OO')) $true
Assert-Equal "'NaN' -> nothing"              ($null -eq (ConvertTo-LeaseNumber 'NaN'))  $true
Assert-Equal "'Infinity' -> nothing"         ($null -eq (ConvertTo-LeaseNumber 'Infinity')) $true

# =============================
# RANGE CHECKS
# =============================

Assert-Equal "Term 36 is OK"                 (Test-LeaseValue -Value 36   -Min 12 -Max 84 -WholeNumber) $true
Assert-Equal "Term 36.5 rejected"            (Test-LeaseValue -Value 36.5 -Min 12 -Max 84 -WholeNumber) $false
Assert-Equal "Term 11 rejected"              (Test-LeaseValue -Value 11   -Min 12 -Max 84 -WholeNumber) $false
Assert-Equal "Term 84 is OK (edge)"          (Test-LeaseValue -Value 84   -Min 12 -Max 84 -WholeNumber) $true
Assert-Equal "Missing value rejected"        (Test-LeaseValue -Value $null -Min 0) $false
Assert-Equal "Negative MF rejected"          (Test-LeaseValue -Value -0.002 -Min 0 -Max $LeaseLimits.MoneyFactorMax) $false
Assert-Equal "MF 0.0125 is OK (edge)"        (Test-LeaseValue -Value 0.0125 -Min 0 -Max $LeaseLimits.MoneyFactorMax) $true
Assert-Equal "Residual 150% rejected"        (Test-LeaseValue -Value 150 -Min 0 -Max $LeaseLimits.ResidualPctMax) $false

# =============================
# NUMBERS THAT CAN'T BE A REAL LEASE
# =============================

Assert-Throws "Net cap at/below residual"    { Get-LeasePayment -CapCost 25000 -DownPayment 8000 -ResidualValue 18000 -MoneyFactor 0.002 -Term 36 -TaxRatePercent 6 } "negative depreciation"
Assert-Throws "Negative money factor"        { Get-LeasePayment -CapCost 30000 -ResidualValue 18000 -MoneyFactor -0.002 -Term 36 -TaxRatePercent 6 } "Money Factor"
Assert-Throws "Term 36.5"                    { Get-LeasePayment -CapCost 30000 -ResidualValue 18000 -MoneyFactor 0.002 -Term 36.5 -TaxRatePercent 6 } "whole number"
Assert-Throws "Term 0"                       { Get-LeasePayment -CapCost 30000 -ResidualValue 18000 -MoneyFactor 0.002 -Term 0 -TaxRatePercent 6 } "whole number"
Assert-Throws "Zero cap cost"                { Get-LeasePayment -CapCost 0 -ResidualValue 0 -MoneyFactor 0.002 -Term 36 -TaxRatePercent 6 } "Capitalized Cost"

# =============================
# SUMMARY
# =============================

Write-Host ""
Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
