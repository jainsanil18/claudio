# win-async.ps1 - bridge WinRT IAsyncOperation/IAsyncAction to something
# Windows PowerShell 5.1 can block on. Dot-sourced by listener/voice-check.
#
# WinRT projection here is runtime-only (ContentType=WindowsRuntime) so it
# needs NO Windows SDK / Windows.winmd on the machine.

try { Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop } catch { }

# Force-load the WinRT speech types via the runtime projection accelerator.
$null = [Windows.Media.SpeechRecognition.SpeechRecognizer, Windows.Media.SpeechRecognition, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]

$script:WV_SR_Result  = [Windows.Media.SpeechRecognition.SpeechRecognitionResult, Windows.Media.SpeechRecognition, ContentType = WindowsRuntime]
$script:WV_SR_Compile = [Windows.Media.SpeechRecognition.SpeechRecognitionCompilationResult, Windows.Media.SpeechRecognition, ContentType = WindowsRuntime]

# AsTask<T>(IAsyncOperation<T>)  - one generic arg, one param of IAsyncOperation`1
$script:WV_AsTaskOp = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.IsGenericMethodDefinition -and
        $_.GetGenericArguments().Count -eq 1 -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

# AsTask(IAsyncAction) - non-generic, one IAsyncAction param
$script:WV_AsTaskAct = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and
        -not $_.IsGenericMethodDefinition -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.FullName -eq 'Windows.Foundation.IAsyncAction'
    })[0]

function Wait-WinRtOp {
    # Block on an IAsyncOperation<T> and return its result.
    param($Operation, [Type]$ResultType, [int]$TimeoutMs = 60000)
    $m    = $script:WV_AsTaskOp.MakeGenericMethod($ResultType)
    $task = $m.Invoke($null, @($Operation))
    if (-not $task.Wait($TimeoutMs)) { throw "WinRT op timed out after ${TimeoutMs}ms" }
    return $task.Result
}

function Wait-WinRtAction {
    # Block on an IAsyncAction (no result).
    param($Action, [int]$TimeoutMs = 60000)
    $task = $script:WV_AsTaskAct.Invoke($null, @($Action))
    if (-not $task.Wait($TimeoutMs)) { throw "WinRT action timed out after ${TimeoutMs}ms" }
}
