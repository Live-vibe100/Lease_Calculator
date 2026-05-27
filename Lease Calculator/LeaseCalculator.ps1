Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =============================
# FORM SETUP
# =============================

$form = New-Object System.Windows.Forms.Form
$form.Text = "Lease Calculator"
$form.Size = New-Object System.Drawing.Size(1400, 920)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = 'FixedDialog'
$form.AutoScroll = $false
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::White

# =============================
# COLORS
# =============================

$colorValid = [System.Drawing.Color]::White
$colorInvalid = [System.Drawing.Color]::FromArgb(255, 230, 230)
$borderInvalid = [System.Drawing.Color]::FromArgb(220, 60, 60)

# =============================
# TRACKING COLLECTIONS
# =============================

$script:allTextBoxes = @()
$script:syncingAPR = $false
$script:syncingMF = $false
$script:syncingResVal = $false
$script:syncingResPct = $false

# =============================
# HELPER FUNCTIONS
# =============================

function Add-LabeledField {
    param(
        [string]$Label,
        [string]$Description,
        [string]$Placeholder,
        [int]$Y
    )

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Label
    $lbl.Location = New-Object System.Drawing.Point(20, $Y)
    $lbl.Size = New-Object System.Drawing.Size(220, 20)
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(460, $Y)
    $txt.Size = New-Object System.Drawing.Size(170, 22)
    $txt.Tag = $Placeholder
    $txt.Text = $Placeholder
    $txt.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($txt)

    # Placeholder behavior - focus
    $txt.Add_GotFocus({
        if ($this.Text -eq $this.Tag) {
            $this.Text = ""
            $this.ForeColor = [System.Drawing.Color]::Black
        }
    })

    # Placeholder behavior - leave
    $txt.Add_LostFocus({
        if ($this.Text -eq "" -or $this.Text -eq $this.Tag) {
            $this.Text = $this.Tag
            $this.ForeColor = [System.Drawing.Color]::Gray
            $this.BackColor = $colorValid
        }
    })

    $desc = New-Object System.Windows.Forms.Label
    $desc.Text = $Description
    $desc.Location = New-Object System.Drawing.Point(20, ($Y + 22))
    $desc.Size = New-Object System.Drawing.Size(380, 42)
    $desc.MaximumSize = New-Object System.Drawing.Size(380, 0)
    $desc.AutoSize = $true
    $desc.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $desc.ForeColor = [System.Drawing.Color]::DarkSlateGray
    $form.Controls.Add($desc)

    $script:allTextBoxes += $txt
    return $txt
}

function Get-FieldValue {
    param([System.Windows.Forms.TextBox]$Field)
    $raw = $Field.Text.Trim()
    if ($raw -eq "" -or $raw -eq $Field.Tag) { return $null }
    # Strip $, commas, % signs
    $raw = $raw -replace '[\$,%]', ''
    $raw = $raw.Trim()
    $val = 0.0
    if ([double]::TryParse($raw, [ref]$val)) { return $val }
    return $null
}

function Validate-PositiveNumber {
    param([System.Windows.Forms.TextBox]$Field, [bool]$Required = $true)
    $val = Get-FieldValue $Field
    if ($null -eq $val) {
        if ($Required) {
            $Field.BackColor = $colorInvalid
            return $false
        }
        return $true
    }
    if ($val -lt 0) {
        $Field.BackColor = $colorInvalid
        return $false
    }
    $Field.BackColor = $colorValid
    return $true
}

function Validate-NonNegativeNumber {
    param([System.Windows.Forms.TextBox]$Field)
    $val = Get-FieldValue $Field
    if ($null -eq $val) { return $true }
    if ($val -lt 0) {
        $Field.BackColor = $colorInvalid
        return $false
    }
    $Field.BackColor = $colorValid
    return $true
}

function Validate-Range {
    param([System.Windows.Forms.TextBox]$Field, [double]$Min, [double]$Max, [bool]$Required = $true)
    $val = Get-FieldValue $Field
    if ($null -eq $val) {
        if ($Required) {
            $Field.BackColor = $colorInvalid
            return $false
        }
        return $true
    }
    if ($val -lt $Min -or $val -gt $Max) {
        $Field.BackColor = $colorInvalid
        return $false
    }
    $Field.BackColor = $colorValid
    return $true
}

# =============================
# INPUT FIELDS
# =============================

$txtMSRP = Add-LabeledField `
    -Label "MSRP" `
    -Description "Manufacturer's Suggested Retail Price. The original sticker price of the vehicle before discounts or incentives." `
    -Placeholder "e.g. 35000.00" `
    -Y 20

$txtCapCost = Add-LabeledField `
    -Label "Capitalized Cost" `
    -Description "The agreed-upon selling price of the vehicle before rebates or down payment reductions." `
    -Placeholder "e.g. 33000.00" `
    -Y 80

$txtFees = Add-LabeledField `
    -Label "Fees" `
    -Description "Combined lease fees such as acquisition fee, documentation fee, etc." `
    -Placeholder "e.g. 895.00" `
    -Y 140

$txtCapReduction = Add-LabeledField `
    -Label "Capitalized Cost Reduction" `
    -Description "Rebates, incentives, trade equity, manufacturer incentives, or cash used to reduce the lease amount financed." `
    -Placeholder "e.g. 2000.00" `
    -Y 200

$txtDownPayment = Add-LabeledField `
    -Label "Down Payment" `
    -Description "Cash paid upfront toward the lease. This lowers the monthly payment but increases upfront cost." `
    -Placeholder "e.g. 1500.00" `
    -Y 270

$txtResidualValue = Add-LabeledField `
    -Label "Residual Value ($)" `
    -Description "Estimated vehicle value at the end of the lease term. Usually provided by the leasing company." `
    -Placeholder "e.g. 22750.00" `
    -Y 340

$txtResidualPercent = Add-LabeledField `
    -Label "Residual Percent (Optional)" `
    -Description "Optional percentage used to calculate residual value automatically from MSRP. Example: 65 for 65%." `
    -Placeholder "e.g. 65" `
    -Y 410

$txtMoneyFactor = Add-LabeledField `
    -Label "Money Factor" `
    -Description "Lease interest factor used to calculate finance charges. Example: 0.00180." `
    -Placeholder "e.g. 0.00180" `
    -Y 480

$txtAPR = Add-LabeledField `
    -Label "APR (Optional)" `
    -Description "Optional APR field used to automatically calculate money factor. Example: 4.32." `
    -Placeholder "e.g. 4.32" `
    -Y 550

$txtTerm = Add-LabeledField `
    -Label "Lease Term (Months)" `
    -Description "Length of the lease in months. Typical terms are 24, 36, or 48 months." `
    -Placeholder "e.g. 36" `
    -Y 620

$txtTax = Add-LabeledField `
    -Label "Sales Tax Rate" `
    -Description "Local sales tax rate applied to lease payments. Example: 5.9 for 5.9%." `
    -Placeholder "e.g. 5.9" `
    -Y 690

# =============================
# INPUT VALIDATION ON LEAVE
# =============================

$txtMSRP.Add_LostFocus({ Validate-PositiveNumber -Field $txtMSRP -Required $true | Out-Null })
$txtCapCost.Add_LostFocus({ Validate-PositiveNumber -Field $txtCapCost -Required $true | Out-Null })
$txtFees.Add_LostFocus({ Validate-NonNegativeNumber -Field $txtFees | Out-Null })
$txtCapReduction.Add_LostFocus({ Validate-NonNegativeNumber -Field $txtCapReduction | Out-Null })
$txtDownPayment.Add_LostFocus({ Validate-NonNegativeNumber -Field $txtDownPayment | Out-Null })
$txtResidualValue.Add_LostFocus({ Validate-PositiveNumber -Field $txtResidualValue -Required $false | Out-Null })
$txtResidualPercent.Add_LostFocus({ Validate-Range -Field $txtResidualPercent -Min 0 -Max 100 -Required $false | Out-Null })
$txtMoneyFactor.Add_LostFocus({ Validate-Range -Field $txtMoneyFactor -Min 0.00001 -Max 0.01 -Required $false | Out-Null })
$txtAPR.Add_LostFocus({ Validate-Range -Field $txtAPR -Min 0 -Max 30 -Required $false | Out-Null })
$txtTerm.Add_LostFocus({ Validate-Range -Field $txtTerm -Min 12 -Max 84 -Required $true | Out-Null })
$txtTax.Add_LostFocus({ Validate-Range -Field $txtTax -Min 0 -Max 15 -Required $true | Out-Null })

# =============================
# AUTO-SYNC: APR <-> MONEY FACTOR
# =============================

$txtAPR.Add_TextChanged({
    if ($script:syncingAPR) { return }
    $val = Get-FieldValue $txtAPR
    if ($null -ne $val -and $val -ge 0) {
        $script:syncingMF = $true
        $mf = $val / 2400
        $txtMoneyFactor.Text = $mf.ToString("F5")
        $txtMoneyFactor.ForeColor = [System.Drawing.Color]::Black
        $script:syncingMF = $false
    }
})

$txtMoneyFactor.Add_TextChanged({
    if ($script:syncingMF) { return }
    $val = Get-FieldValue $txtMoneyFactor
    if ($null -ne $val -and $val -ge 0) {
        $script:syncingAPR = $true
        $apr = $val * 2400
        $txtAPR.Text = $apr.ToString("F2")
        $txtAPR.ForeColor = [System.Drawing.Color]::Black
        $script:syncingAPR = $false
    }
})

# =============================
# AUTO-SYNC: RESIDUAL % <-> RESIDUAL $
# =============================

$txtResidualPercent.Add_TextChanged({
    if ($script:syncingResPct) { return }
    $pct = Get-FieldValue $txtResidualPercent
    $msrp = Get-FieldValue $txtMSRP
    if ($null -ne $pct -and $null -ne $msrp -and $msrp -gt 0) {
        $script:syncingResVal = $true
        $rv = $msrp * ($pct / 100)
        $txtResidualValue.Text = $rv.ToString("F2")
        $txtResidualValue.ForeColor = [System.Drawing.Color]::Black
        $script:syncingResVal = $false
    }
})

$txtResidualValue.Add_TextChanged({
    if ($script:syncingResVal) { return }
    $rv = Get-FieldValue $txtResidualValue
    $msrp = Get-FieldValue $txtMSRP
    if ($null -ne $rv -and $null -ne $msrp -and $msrp -gt 0) {
        $script:syncingResPct = $true
        $pct = ($rv / $msrp) * 100
        $txtResidualPercent.Text = $pct.ToString("F2")
        $txtResidualPercent.ForeColor = [System.Drawing.Color]::Black
        $script:syncingResPct = $false
    }
})

# Also recalc residual $ when MSRP changes (if residual % is filled)
$txtMSRP.Add_TextChanged({
    $pct = Get-FieldValue $txtResidualPercent
    $msrp = Get-FieldValue $txtMSRP
    if ($null -ne $pct -and $null -ne $msrp -and $msrp -gt 0) {
        $script:syncingResVal = $true
        $rv = $msrp * ($pct / 100)
        $txtResidualValue.Text = $rv.ToString("F2")
        $txtResidualValue.ForeColor = [System.Drawing.Color]::Black
        $script:syncingResVal = $false
    }
})

# =============================
# OUTPUT LABEL
# =============================

$resultLabel = New-Object System.Windows.Forms.Label
$resultLabel.Location = New-Object System.Drawing.Point(930, 40)
$resultLabel.Size = New-Object System.Drawing.Size(380, 620)
$resultLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$resultLabel.Text = "Results will appear here"
$form.Controls.Add($resultLabel)

# =============================
# CALCULATE BUTTON
# =============================

$btnCalc = New-Object System.Windows.Forms.Button
$btnCalc.Text = "Calculate Lease"
$btnCalc.Location = New-Object System.Drawing.Point(930, 670)
$btnCalc.Size = New-Object System.Drawing.Size(220, 45)
$btnCalc.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnCalc.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnCalc.ForeColor = [System.Drawing.Color]::White
$btnCalc.FlatStyle = 'Flat'
$btnCalc.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnCalc)

# =============================
# RESET BUTTON
# =============================

$btnReset = New-Object System.Windows.Forms.Button
$btnReset.Text = "Reset All"
$btnReset.Location = New-Object System.Drawing.Point(930, 725)
$btnReset.Size = New-Object System.Drawing.Size(105, 35)
$btnReset.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$btnReset.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$btnReset.FlatStyle = 'Flat'
$btnReset.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnReset)

$btnReset.Add_Click({
    foreach ($tb in $script:allTextBoxes) {
        $tb.Text = $tb.Tag
        $tb.ForeColor = [System.Drawing.Color]::Gray
        $tb.BackColor = $colorValid
    }
    $resultLabel.Text = "Results will appear here"
})

# =============================
# COPY RESULTS BUTTON
# =============================

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = "Copy Results"
$btnCopy.Location = New-Object System.Drawing.Point(1045, 725)
$btnCopy.Size = New-Object System.Drawing.Size(105, 35)
$btnCopy.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$btnCopy.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$btnCopy.FlatStyle = 'Flat'
$btnCopy.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnCopy)

$btnCopy.Add_Click({
    if ($resultLabel.Text -ne "Results will appear here") {
        [System.Windows.Forms.Clipboard]::SetText($resultLabel.Text)
        [System.Windows.Forms.MessageBox]::Show("Results copied to clipboard.", "Copied", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

# =============================
# CALCULATION LOGIC
# =============================

$btnCalc.Add_Click({

    # Run validation on all required fields
    $valid = $true
    if (-not (Validate-PositiveNumber -Field $txtMSRP -Required $true)) { $valid = $false }
    if (-not (Validate-PositiveNumber -Field $txtCapCost -Required $true)) { $valid = $false }
    if (-not (Validate-NonNegativeNumber -Field $txtFees)) { $valid = $false }
    if (-not (Validate-NonNegativeNumber -Field $txtCapReduction)) { $valid = $false }
    if (-not (Validate-NonNegativeNumber -Field $txtDownPayment)) { $valid = $false }
    if (-not (Validate-Range -Field $txtTerm -Min 12 -Max 84 -Required $true)) { $valid = $false }
    if (-not (Validate-Range -Field $txtTax -Min 0 -Max 15 -Required $true)) { $valid = $false }

    # Validate one-or-the-other pairs
    $mfVal = Get-FieldValue $txtMoneyFactor
    $aprVal = Get-FieldValue $txtAPR
    if ($null -eq $mfVal -and $null -eq $aprVal) {
        $txtMoneyFactor.BackColor = $colorInvalid
        $txtAPR.BackColor = $colorInvalid
        $valid = $false
    }

    $rvVal = Get-FieldValue $txtResidualValue
    $rpVal = Get-FieldValue $txtResidualPercent
    if ($null -eq $rvVal -and $null -eq $rpVal) {
        $txtResidualValue.BackColor = $colorInvalid
        $txtResidualPercent.BackColor = $colorInvalid
        $valid = $false
    }

    if (-not $valid) {
        [System.Windows.Forms.MessageBox]::Show("Please fix highlighted fields before calculating.", "Validation Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    try {

        $msrp = Get-FieldValue $txtMSRP
        $capCost = Get-FieldValue $txtCapCost
        $fees = Get-FieldValue $txtFees; if ($null -eq $fees) { $fees = 0 }
        $capReduction = Get-FieldValue $txtCapReduction; if ($null -eq $capReduction) { $capReduction = 0 }
        $downPayment = Get-FieldValue $txtDownPayment; if ($null -eq $downPayment) { $downPayment = 0 }
        $term = Get-FieldValue $txtTerm
        $taxRate = (Get-FieldValue $txtTax) / 100

        # =============================
        # MONEY FACTOR LOGIC
        # =============================

        $moneyFactor = Get-FieldValue $txtMoneyFactor
        if ($null -eq $moneyFactor -or $moneyFactor -le 0) {
            $apr = Get-FieldValue $txtAPR
            $moneyFactor = $apr / 2400
        }

        # =============================
        # RESIDUAL LOGIC
        # =============================

        if ($null -ne (Get-FieldValue $txtResidualPercent)) {
            $residualPercent = (Get-FieldValue $txtResidualPercent) / 100
            $residualValue = $msrp * $residualPercent
        }
        else {
            $residualValue = Get-FieldValue $txtResidualValue
        }

        # =============================
        # NET CAPITALIZED COST
        # =============================

        $netCapCost = $capCost + $fees - $capReduction - $downPayment

        # =============================
        # DEPRECIATION
        # =============================

        $depreciation = ($netCapCost - $residualValue) / $term

        # =============================
        # FINANCE CHARGE
        # =============================

        $financeCharge = ($netCapCost + $residualValue) * $moneyFactor

        # =============================
        # BASE PAYMENT
        # =============================

        $basePayment = $depreciation + $financeCharge

        # =============================
        # FINAL PAYMENT
        # =============================

        $monthlyTax = $basePayment * $taxRate
        $monthlyPayment = $basePayment + $monthlyTax

        # =============================
        # TOTAL LEASE COST
        # =============================

        $totalLeaseCost = ($monthlyPayment * $term) + $downPayment

        # =============================
        # DISPLAY RESULTS
        # =============================

        $resultLabel.Text = @"
Net Capitalized Cost:
$($netCapCost.ToString('C'))

Residual Value:
$($residualValue.ToString('C'))

Money Factor:
$([math]::Round($moneyFactor, 5).ToString("F5"))

Depreciation:
$($depreciation.ToString('C')) / mo

Finance Charge:
$($financeCharge.ToString('C')) / mo

Monthly Payment (before tax):
$($basePayment.ToString('C'))

Sales Tax / mo:
$($monthlyTax.ToString('C'))

Monthly Payment (with tax):
$($monthlyPayment.ToString('C'))

Total Lease Cost:
$($totalLeaseCost.ToString('C'))
"@

    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Please verify all fields contain valid numbers.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

# =============================
# RUN FORM
# =============================

[void]$form.ShowDialog()
