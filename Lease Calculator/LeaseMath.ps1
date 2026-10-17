# =============================
# LEASE MATH
# =============================
# The number crunching and input rules for LeaseCalculator.ps1. Kept in its own
# file (no window code) so it can be tested directly: see Tests\Test-LeaseMath.ps1.

# Allowed range for each input. The window uses these to highlight bad fields.
$LeaseLimits = @{
    TermMin        = 12
    TermMax        = 84
    TaxMax         = 15     # percent
    AprMax         = 30     # percent
    ResidualPctMax = 100    # percent of MSRP
}
# Kept in step with AprMax so the two rate fields always agree (30% APR = 0.0125)
$LeaseLimits.MoneyFactorMax = $LeaseLimits.AprMax / 2400

function ConvertTo-LeaseNumber {
    <#
    .SYNOPSIS
        Turns typed text like "$35,000" or "5.9%" into a number.
    .OUTPUTS
        [double], or $null if the text is blank or isn't a real number.
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    # Strip $, commas, % signs
    $clean = ($Text -replace '[\$,%]', '').Trim()
    $val = 0.0
    if (-not [double]::TryParse($clean, [ref]$val)) { return $null }
    # TryParse happily accepts "NaN" and "Infinity" - those aren't usable numbers
    if ([double]::IsNaN($val) -or [double]::IsInfinity($val)) { return $null }
    return $val
}

function Test-LeaseValue {
    <#
    .SYNOPSIS
        Checks a number is inside an allowed range (Min and Max included).
    .OUTPUTS
        [bool]. A missing value ($null) is never valid - callers decide if a field is optional.
    #>
    param(
        # Nullable double so text like "-0.002" is converted, never compared as text
        [Nullable[double]]$Value,
        [double]$Min = 0,
        [double]$Max = [double]::MaxValue,
        [switch]$WholeNumber
    )

    if ($null -eq $Value) { return $false }
    if ($Value -lt $Min -or $Value -gt $Max) { return $false }
    if ($WholeNumber -and $Value -ne [math]::Truncate($Value)) { return $false }
    return $true
}

function ConvertTo-MoneyFactor {
    <# .SYNOPSIS Converts an APR (e.g. 4.32) to a money factor (0.0018). #>
    param([double]$Apr)
    return $Apr / 2400
}

function ConvertTo-Apr {
    <# .SYNOPSIS Converts a money factor (e.g. 0.0018) to an APR (4.32). #>
    param([double]$MoneyFactor)
    return $MoneyFactor * 2400
}

function Get-ResidualValue {
    <# .SYNOPSIS Residual dollars from MSRP and residual percent (65 = 65%). #>
    param([double]$Msrp, [double]$Percent)
    return $Msrp * ($Percent / 100)
}

function Get-ResidualPercent {
    <# .SYNOPSIS Residual percent (65 = 65%) from MSRP and residual dollars. #>
    param([double]$Msrp, [double]$ResidualValue)
    return ($ResidualValue / $Msrp) * 100
}

function Get-LeasePayment {
    <#
    .SYNOPSIS
        Works out a lease payment with the standard lease formula.
    .DESCRIPTION
        Net Cap Cost   = Cap Cost + Fees - Cap Cost Reduction - Down Payment
        Depreciation   = (Net Cap Cost - Residual) / Term
        Finance Charge = (Net Cap Cost + Residual) x Money Factor
        Monthly        = (Depreciation + Finance Charge) x (1 + Tax Rate)
        Total          = Monthly x Term + Down Payment

        Throws an ArgumentException with a plain-English message when the numbers
        can't describe a real lease (e.g. net cap cost at or below the residual).
    .OUTPUTS
        PSCustomObject: NetCapCost, ResidualValue, MoneyFactor, Depreciation, FinanceCharge,
        BasePayment, MonthlyTax, MonthlyPayment, TotalLeaseCost.
    #>
    param(
        [double]$CapCost,
        [double]$Fees = 0,
        [double]$CapReduction = 0,
        [double]$DownPayment = 0,
        [double]$ResidualValue,
        [double]$MoneyFactor,
        [double]$Term,
        [double]$TaxRatePercent
    )

    if ($CapCost -le 0) { throw [System.ArgumentException]::new("Capitalized Cost must be more than zero.") }
    if ($Fees -lt 0 -or $CapReduction -lt 0 -or $DownPayment -lt 0) {
        throw [System.ArgumentException]::new("Fees, reductions, and down payment can't be negative.")
    }
    if ($ResidualValue -lt 0) { throw [System.ArgumentException]::new("Residual Value can't be negative.") }
    if ($MoneyFactor -lt 0) { throw [System.ArgumentException]::new("Money Factor can't be negative.") }
    if ($TaxRatePercent -lt 0) { throw [System.ArgumentException]::new("Sales Tax Rate can't be negative.") }
    if (-not (Test-LeaseValue -Value $Term -Min 1 -WholeNumber)) {
        throw [System.ArgumentException]::new("Lease Term must be a whole number of months.")
    }

    $netCapCost = $CapCost + $Fees - $CapReduction - $DownPayment

    # A lease only makes sense if you're paying down some of the car's value
    if ($netCapCost -le $ResidualValue) {
        throw [System.ArgumentException]::new(
            "Net Capitalized Cost ($($netCapCost.ToString('C'))) is at or below the Residual Value " +
            "($($ResidualValue.ToString('C'))), which would mean a negative depreciation. " +
            "Double-check the down payment and cap cost reduction.")
    }

    $depreciation = ($netCapCost - $ResidualValue) / $Term
    $financeCharge = ($netCapCost + $ResidualValue) * $MoneyFactor
    $basePayment = $depreciation + $financeCharge
    $monthlyTax = $basePayment * ($TaxRatePercent / 100)
    $monthlyPayment = $basePayment + $monthlyTax

    return [PSCustomObject]@{
        NetCapCost     = $netCapCost
        ResidualValue  = $ResidualValue
        MoneyFactor    = $MoneyFactor
        Depreciation   = $depreciation
        FinanceCharge  = $financeCharge
        BasePayment    = $basePayment
        MonthlyTax     = $monthlyTax
        MonthlyPayment = $monthlyPayment
        TotalLeaseCost = ($monthlyPayment * $Term) + $DownPayment
    }
}
