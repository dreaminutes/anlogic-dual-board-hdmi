param(
 [ValidateSet('Validate','Synthesis','Physical','Bit','All')][string]$Stage='Validate',
 [string]$TdExe=$env:TD_EXE
)
$ErrorActionPreference='Stop'
if (-not $TdExe) {
 $candidate=Get-Command td_commands_prompt.exe -ErrorAction SilentlyContinue
 if ($candidate) {$TdExe=$candidate.Source}
}
if (-not $TdExe -or -not (Test-Path -LiteralPath $TdExe -PathType Leaf)) {
 throw 'Set TD_EXE or use -TdExe with the installed td_commands_prompt.exe path.'
}
$steps=if($Stage -eq 'All'){@('Synthesis','Physical','Bit')}else{@($Stage)}
foreach($step in $steps){
 $buildDirectory=Join-Path $PSScriptRoot 'build'
 [IO.Directory]::CreateDirectory($buildDirectory) | Out-Null
 $log=Join-Path $buildDirectory ($step.ToLower()+'.log')
 $script=(Join-Path $PSScriptRoot ($step.ToLower()+'.tcl')).Replace('\','/')
 & $TdExe $script 2>&1 | Tee-Object -FilePath $log
 $exitCode=$LASTEXITCODE
 $output=Get-Content -LiteralPath $log -Raw
 $marker='PACKAGE_'+$step.ToUpper()+'_COMPLETE'
 if($exitCode -ne 0 -or $output -notmatch [regex]::Escape($marker) -or
    $output -match 'PACKAGE_BUILD_FAILED|(?im)^\s*(?:[A-Z]+-\d+\s*:?\s*)?ERROR\b'){
   throw "$step failed; inspect $log"
 }
}
