﻿using namespace System.Windows.Forms

class Host
{
    # Keeps track of the hosts and performs actions on them

    static [Host[]]$Hosts = @()
    [String]$Name
    [String]$Mac
    [Bool]$Status
    [Int]$Column
    [Int]$Row

    Host([String]$name, [String]$mac, [Int]$column, [Int]$row)
    {
        $this.Name = $name
        Write-Host -NoNewline ("{0}: " -f $this.Name)
        $this.Status = Test-Connection -ComputerName $this.Name -Count 1 -Quiet
        # $this.Status = ([String](ping -n 1 -w 50 $this.Name)) -like "*Reply*"
        # $this.Status = [Bool][System.Net.NetworkInformation.Ping]::new().SendPingAsync($this.Name, 50).Result
        Write-Host -NoNewline ("status={0}, " -f $this.Status)
        if($mac)
        {
            $this.Mac = $mac
        }
        elseif($this.Status)
        {
            $this.Mac = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled='True'" -ComputerName $this.Name | Select-Object -First 1 -ExpandProperty MACAddress
        }
        Write-Host -NoNewline ("mac={0}, " -f $this.Mac)
        $this.Column = $column
        Write-Host -NoNewline ("column={0}, " -f $this.Column)
        $this.Row = $row
        Write-Host ("row={0}" -f $this.Row)
    }

    static [void] Populate([String]$path, [String]$delimiter)
    {
        # Creates [Host] objects from given .csv file
        [Host]::Hosts = @()
        Import-Csv $path -Delimiter $delimiter | ForEach-Object {[Host]::Hosts += [Host]::new($_.Nimi, $_.Mac, [Int]$_.Sarake, [Int]$_.Rivi)}
    }

    static [void] Display()
    {
        # Displays hosts in the $script:table
        $script:table.Rows | ForEach-Object {$_.Cells | ForEach-Object { $_.Value = ""; $_.ToolTipText = "" }}
        $script:table.ColumnCount = ([Host]::Hosts | ForEach-Object {$_.Column} | Measure-Object -Maximum).Maximum
        $script:table.RowCount = ([Host]::Hosts | ForEach-Object {$_.Row} | Measure-Object -Maximum).Maximum
        $script:table.Columns | ForEach-Object {
            $_.SortMode = [DataGridViewColumnSortMode]::NotSortable
            $_.HeaderText = [Char]($_.Index + 65) # Sets the column headers to A, B, C...
            $_.HeaderCell.Style.Alignment = [DataGridViewContentAlignment]::MiddleCenter
            $_.Width = 80
        }
        $script:table.Rows | ForEach-Object {
            $_.HeaderCell.Value = [String]($_.Index + 1) # Sets the row headers to 1, 2, 3...
            $_.HeaderCell.Style.Alignment = [DataGridViewContentAlignment]::MiddleCenter
            $_.Height = 80
        }  
        foreach($h in [Host]::Hosts)
        {
            $cell = $script:table[($h.Column - 1), ($h.Row - 1)]
            $cell.Value = $h.Name
            $cell.ToolTipText = $h.Mac
            if($h.Status)
            {
                $cell.Style.ForeColor = [System.Drawing.Color]::Green
                $cell.Style.SelectionForeColor = [System.Drawing.Color]::Green
            }
            else
            {
                $cell.Style.ForeColor = [System.Drawing.Color]::Red
                $cell.Style.SelectionForeColor = [System.Drawing.Color]::Red
            }
        }
    }

    static [void] Run([ScriptBlock]$command, [Bool]$AsJob)
    {
        # Runs a specified commands on all selected remote hosts
        $hostnames = [Host]::Hosts | Where-Object {$_.Status -and ($script:table[($_.Column - 1), ($_.Row - 1)]).Selected} | ForEach-Object {$_.Name} # Gets the names of the hosts that are online and selected
        if ($null -eq $hostnames) { return }
        if($AsJob)
        {
            Invoke-Command -ComputerName $hostnames -Credential $script:credential -ScriptBlock $command -AsJob
        }
        else
        {
            Invoke-Command -ComputerName $hostnames -Credential $script:credential -ScriptBlock $command | Write-Host
        }
    }

    static [void] Run([String]$executable, [String]$argument, [String]$workingDirectory)
    {
        # Runs a specified interactive program on all selected remote hosts by creating a scheduled task on currently logged on user then running it and finally deleting it
        $hostnames = [Host]::Hosts | Where-Object {$_.Status -and ($script:table[($_.Column - 1), ($_.Row - 1)]).Selected} | ForEach-Object {$_.Name}
        if ($null -eq $hostnames) { return }
        Invoke-Command -ComputerName $hostnames -Credential $script:credential -ArgumentList $executable, $argument, $workingDirectory -AsJob -ScriptBlock {
            param($executable, $argument, $workingDirectory)
            if($argument -eq ""){ $argument = " " } # There must be a better way to do this xd
            $action = New-ScheduledTaskAction -Execute $executable -Argument $argument -WorkingDirectory $workingDirectory
            $user = Get-Process -Name "explorer" -IncludeUserName | Select-Object -First 1 -ExpandProperty UserName # Get the user that is logged on the remote computer
            $principal = New-ScheduledTaskPrincipal -UserId $user
            $task = New-ScheduledTask -Action $action -Principal $principal
            $taskname = "Luokanhallinta"
            try 
            {
                $registeredTask = Get-ScheduledTask $taskname -ErrorAction SilentlyContinue
            } 
            catch 
            {
                $registeredTask = $null
            }
            if ($registeredTask)
            {
                Unregister-ScheduledTask -InputObject $registeredTask -Confirm:$false
            }
            $registeredTask = Register-ScheduledTask $taskname -InputObject $task
            Start-ScheduledTask -InputObject $registeredTask
            Unregister-ScheduledTask -InputObject $registeredTask -Confirm:$false
        }
    }

    static [void] Wake()
    {
        # Boots selected remote hosts by broadcasting the magic packet (Wake-On-LAN)
        $macs = [Host]::Hosts | Where-Object {($script:table[($_.Column - 1), ($_.Row - 1)]).Selected -and $_} | ForEach-Object {$_.Mac} # Get mac addresses of selected hosts
        $port = 9
        $broadcast = [Net.IPAddress]::Parse("255.255.255.255")
        foreach($m in $macs)
        {
            $m = (($m.replace(":", "")).replace("-", "")).replace(".", "")
            $target = 0, 2, 4, 6, 8, 10 | ForEach-Object {[convert]::ToByte($m.substring($_, 2), 16)}
            $packet = (,[byte]255 * 6) + ($target * 16) # Creates the magic packet
            $UDPclient = [System.Net.Sockets.UdpClient]::new()
            $UDPclient.Connect($broadcast, $port)
            $UDPclient.Send($packet, 102) # Sends the magic packet
        }
    }
}

class BaseCommand : ToolStripMenuItem
{
    # Defines base functionality for a command. Also contains some static members which handle command initialization.

    [Scriptblock]$Script
    static $Commands = [ordered]@{
        "Valitse" = @(
            [BaseCommand]::new("Kaikki", {$script:table.SelectAll()}),
            [BaseCommand]::new("Käänteinen", {$script:table.Rows | ForEach-Object {$_.Cells | ForEach-Object { $_.Selected = !$_.Selected }}})
            [BaseCommand]::new("Ei mitään", {$script:table.ClearSelection()})
        )
        "Tietokone" = @(
            [BaseCommand]::new("Käynnistä", {[Host]::Wake()})
            [BaseCommand]::new("Käynnistä uudelleen", {[Host]::Run({shutdown /r /t 10 /c "Luokanhallinta on ajastanut uudelleen käynnistyksen"}, $true)})
            [BaseCommand]::new("Sammuta", {[Host]::Run({shutdown /s /t 10 /c "Luokanhallinta on ajastanut sammutuksen"}, $true)})
        )
        "VBS3" = @(
            [InteractiveCommand]::new("Käynnistä", "VBS3_64.exe", "", "C:\Program Files\Bohemia Interactive Simulations\VBS3 3.9.0.FDF EZYQC_FI")
            [BaseCommand]::new("Synkkaa addonit", {[Host]::Run({robocopy '\\PSPR-Storage' 'C:\Program Files\Bohemia Interactive Simulations\VBS3 3.9.0.FDF EZYQC_FI\mycontent\addons' /MIR /XO /R:2 /W:10}, $true)})
            [BaseCommand]::new("Sulje", {[Host]::Run({Stop-Process -ProcessName VBS3_64}, $true)})
        )
        "SteelBeasts" = @(
            [BaseCommand]::new("Käynnistä", {[Host]::Run("SBPro64CM.exe", "", "C:\Program Files\eSim Games\SB Pro FI\Release")})
            [BaseCommand]::new("Sulje", {[Host]::Run({Stop-Process -ProcessName SBPro64CM}, $true)})
        )
        "Muu" = @(
            [BaseCommand]::new("Päivitä", {[Host]::Populate("$PSScriptRoot\luokka.csv", " "); [Host]::Display()})
            [BaseCommand]::new("Vaihda käyttäjä...", {$script:credential = Get-Credential -Message "Käyttäjällä tulee olla järjestelmänvalvojan oikeudet hallittaviin tietokoneisiin" -UserName $(whoami)})
            [InteractiveCommand]::new("Chrome", "chrome.exe", "", "C:\Program Files (x86)\Google\Chrome\Application")
            [BaseCommand]::new("Aja...", {[Host]::Run([Scriptblock]::Create((Read-Host "Komento")), $false)})
            [BaseCommand]::new("Sulje", {$script:root.Close()})
        )
    } 

    BaseCommand([String]$name, [Scriptblock]$script) : base($name)
    {
        $this.Script = $script
    }

    BaseCommand([String]$name) : base($name){}

    [void] OnClick([System.EventArgs]$e)
    {
        ([ToolStripMenuItem]$this).OnClick($e)
        & $this.Script
    }

    static [void] Display()
    {
        foreach($category in [BaseCommand]::Commands.keys) # Iterates over command categories
        {
            # Create a menu for each category
            $menu = [ToolStripMenuItem]::new()
            $menu.Text = $category
            $script:menubar.Items.Add($menu)
            foreach($command in [BaseCommand]::Commands[$category]) # Iterates over commands in each category
            {
                # Add command to menu
                $menu.DropDownItems.Add($command)
            }
        }
    }
}

class PopUpCommand : BaseCommand
{
    # Adds functionality to display a form and widgets to define settings before running the command

    [Object[]]$Widgets
    [Scriptblock]$ClickScript
    [Scriptblock]$RunScript

    PopUpCommand([String]$name, [Object[]]$widgets, [ScriptBlock]$clickScript, [Scriptblock]$runScript) : base($name + "...")
    {
        $this.Widgets = $widgets
        $this.ClickScript = $clickScript
        $this.RunScript = $runScript
    }

    [void] OnClick([System.EventArgs]$e)
    {
        ([ToolStripMenuItem]$this).OnClick($e)
        $form = [Form]::new()
        $form.Text = $this.Text
        $form.AutoSize = $true
        $form.FormBorderStyle = [FormBorderStyle]::FixedToolWindow
        $button = [RunButton]::new($this, $form)
        & $this.ClickScript
        $form.ShowDialog()
    }

    [void] Run(){ & $this.RunScript }
}

class InteractiveCommand : PopUpCommand
{
    # Popup command with three fields for running an interactive program on remote hosts

    [Object[]]$Widgets = @(
        (New-Object Label -Property @{
            Text = "Ohjelma:"
            AutoSize = $true
            Anchor = [AnchorStyles]::Right
        }),
        (New-Object TextBox -Property @{
            Width = 300
            Anchor = [AnchorStyles]::Left
        }),
        (New-Object Label -Property @{
            Text = "Parametri:"
            AutoSize = $true
            Anchor = [AnchorStyles]::Right
        }),
        (New-Object TextBox -Property @{
            Width = 300
            Anchor = [AnchorStyles]::Left
        }),
        (New-Object Label -Property @{
            Text = "Polku:"
            AutoSize = $true
            Anchor = [AnchorStyles]::Right
        }),
        (New-Object TextBox -Property @{
            Width = 300
            Anchor = [AnchorStyles]::Left
        })
    )
    
    [Scriptblock]$ClickScript = {
        $form.Width = 410
        $form.Height = 175
        $grid = [TableLayoutPanel]::new()
        $grid.CellBorderStyle = [TableLayoutPanelCellBorderStyle]::Inset
        $grid.Location = [System.Drawing.Point]::new(0, 0)
        $grid.AutoSize = $true
        $grid.Padding = [Padding]::new(10)
        $grid.ColumnCount = 2
        $grid.RowCount = 4
        $grid.Controls.AddRange($this.Widgets)
        $button.Dock = [DockStyle]::Bottom
        $grid.Controls.Add($button)
        $grid.SetColumnSpan($button, 2)
        $form.Controls.Add($grid)
    }
    [Scriptblock]$RunScript = {
        $executable = ($this.Widgets[1]).Text
        $argument = ($this.Widgets[3]).Text
        $workingDirectory = ($this.Widgets[5]).Text
        [Host]::Run($executable, $argument, $workingDirectory)
    }

    InteractiveCommand([String]$name, [String]$executable, [String]$argument, [String]$workingDirectory) : base($name, $this.Widgets, $this.ClickScript, $this.RunScript)
    {
        # Sets default values for the fields
        ($this.Widgets[1]).Text = $executable
        ($this.Widgets[3]).Text = $argument
        ($this.Widgets[5]).Text = $workingDirectory
    }
}

class RunButton : Button
{
    # This had to be done

    [BaseCommand]$Command
    [Form]$Form

    RunButton([BaseCommand]$command, [Form]$form)
    {
        $this.Command = $command
        $this.Form = $form
        $this.Text = "Aja"
    }

    [void] OnClick([System.EventArgs]$e)
    {
        ([Button]$this).OnClick($e)
        $this.Command.Run()
        $this.Form.Close()
    }
}

[Host]::Populate("$PSScriptRoot\luokka.csv", " ")
$script:root = [Form]::new()
$root.Text = "Luokanhallinta v0.3"
$root.Width = 1280
$root.Height = 720

$script:table = [DataGridView]::new()
$table.Dock = [DockStyle]::Fill
$table.AllowUserToAddRows = $false
$table.AllowUserToDeleteRows = $false
$table.AllowUserToResizeColumns = $false
$table.AllowUserToResizeRows = $false
$table.AllowUserToOrderColumns = $false
$table.ReadOnly = $true
$table.ColumnHeadersHeightSizeMode = [DataGridViewColumnHeadersHeightSizeMode]::DisableResizing
$table.ColumnHeadersHeight = 20
$table.RowHeadersWidthSizeMode = [DataGridViewRowHeadersWidthSizeMode]::DisableResizing
$table.RowHeadersWidth = 20
($table.RowsDefaultCellStyle).ForeColor = [System.Drawing.Color]::Red
($table.RowsDefaultCellStyle).SelectionForeColor = [System.Drawing.Color]::Red
($table.RowsDefaultCellStyle).SelectionBackColor = [System.Drawing.Color]::LightGray
($table.RowsDefaultCellStyle).Alignment = [DataGridViewContentAlignment]::MiddleCenter
$table.SelectionMode = [DataGridViewSelectionMode]::CellSelect
$root.Controls.Add($table)
[Host]::Display()

# Following event handlers implement various ways of making a selection (aamuja)
$table.Add_KeyDown({if($_.KeyCode -eq [Keys]::ControlKey){ $script:control = $true }})
$table.Add_KeyUp({if($_.KeyCode -eq [Keys]::ControlKey){ $script:control = $false }})
$table.Add_CellMouseDown({
    if($_.RowIndex -eq -1 -and $_.ColumnIndex -ne -1)
    {
        if(!$script:control){ $script:table.ClearSelection()}
        $script:startColumn = $_.ColumnIndex
    }
    elseif($_.ColumnIndex -eq -1 -and $_.RowIndex -ne -1)
    {
        if(!$script:control){ $script:table.ClearSelection()}
        $script:startRow = $_.RowIndex
    }
})
$table.Add_CellMouseUp({
    if($_.RowIndex -eq -1 -and $_.ColumnIndex -ne -1)
    {
        $endColumn = $_.ColumnIndex
        $min = ($script:startColumn, $endColumn | Measure-Object -Min).Minimum
        $max = ($script:startColumn, $endColumn | Measure-Object -Max).Maximum
        for($c = $min; $c -le $max; $c++)
        {
            for($r = 0; $r -lt $this.RowCount; $r++)
            {
                if($_.Button -eq [MouseButtons]::Left)
                {
                    $this[[Int]$c, [Int]$r].Selected = $true
                }
                elseif($_.Button -eq [MouseButtons]::Right)
                {
                    $this[[Int]$c, [Int]$r].Selected = $false
                }
            }
        }
    }
    elseif($_.ColumnIndex -eq -1 -and $_.RowIndex -ne -1)
    {
        $endRow = $_.RowIndex
        $min = ($script:startRow, $endRow | Measure-Object -Min).Minimum
        $max = ($script:startRow, $endRow | Measure-Object -Max).Maximum
        for($r = $min; $r -le $max; $r++)
        {
            for($c = 0; $c -lt $this.ColumnCount; $c++)
            {
                if($_.Button -eq [MouseButtons]::Left)
                {
                    $this[[Int]$c, [Int]$r].Selected = $true
                }
                elseif($_.Button -eq [MouseButtons]::Right)
                {
                    $this[[Int]$c, [Int]$r].Selected = $false
                }
            }
        }
    }
    elseif($_.Button -eq [MouseButtons]::Right)
    {
        if($_.ColumnIndex -ne -1 -and $_.RowIndex -ne -1)
        {
            $this[$_.ColumnIndex, $_.RowIndex].Selected = $false
        }
        else
        {
            $this.ClearSelection()
        }
    }
})

$script:menubar = [MenuStrip]::new()
$root.MainMenuStrip = $menubar
$menubar.Dock = [DockStyle]::Top
$root.Controls.Add($menubar)
[BaseCommand]::Display()

$script:credential = Get-Credential -Message "Käyttäjällä tulee olla järjestelmänvalvojan oikeudet hallittaviin tietokoneisiin" -UserName $(whoami)
[void]$root.showDialog()
    