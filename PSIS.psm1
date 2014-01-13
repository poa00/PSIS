﻿<#
.SYNOPSIS
   Invoke the PSIS WebServer

.DESCRIPTION
   Invoke the PSIS WebServer. 
   
   PSIS (PowerShell (Information Server) is a very lightweight WebServer written entierly in PowerShell.
   PSIS enables the user to very quickly expose HTML or simple JSON endpoints to the network.

    The -ProcessRequest parameter takes a scriptblock which is executed on every request.

    There are four automatic variables avaiable to the user in ProcessRequest.
    Listed here with their associated types.

        $Context   [System.Net.HttpListenerContext]
        $User      [System.Security.Principal.GenericPrincipal]
        $Request   [System.Net.HttpListenerRequest]
        $Response  [System.Net.HttpListenerResponse]

    The $Request object is extended with three NoteProperty members. 

        $Request.RequestBody    The RequestBody contains a string representation of the inputstream
                                This could be JSON objects being sent in with a PUT or POST request.
        $Request.RequestBuffer  The RequestBuffer is the raw [byte[]] buffer of the inputstream
        $Request.RequestObject  The RequestObject property is the RequestBody deserialized as JSON 
                                to powershell objects

    The $Response object is extended with one NoteProperty member. 

        $Response.ResponseFile  If this is set to a valid filename. Then PSIS will send the file 
                                back to the calling agent.

    Write-Verbose is not the original cmdlet in the context of the ProcessRequest ScriptBlock. It is an overlayed 
    function which talks back to the main thread using a synchronized queue object which in its turn outputs the 
    messages using the original Write-Verbose. The function in the ProcessRequest ScriptBlock is called the same 
    for convinience. This enables us to output debugging info to the screen when using the -Verbose switch.

.PARAMETER URL
    Specifies the listening URL. Default is http://*:8080/. See the System.Net.HttpListener documentation for details
    of the format.

.PARAMETER AuthenticationSchemes
    Specifies the authentication scheme. Default is Negotiate (kerberos). The "none" value is not supported, 
    use "Anonymous" instead.

.PARAMETER RunspacesCount
    Specifies the number of PowerShell Runspaces used in the RunspacePool internally. More RunSpaces allows 
    for more concurrent requests. Default is 4.

.PARAMETER ProcessRequest
    This is the scriptblock which is executed per request.

    If the $response.ResponseFile property has been set to a file. Then PSIS will send that file to the 
    calling agent.

    If the ScriptBlock returns a single string then that will be assumed to be html.
    The string will then be sent directly to the response stream as "text/html".

    If the ScriptBlock returns other PS objects then these are converted to JSON objects and written to the 
    response stream as JSON with the "application/json" contenttype.

.PARAMETER Modules
    A list of modules to be loaded for the internal runspacepool.

.PARAMETER Impersonate
    Use to impersonate the calling user. PSIS enters impersonation on the powershell thread befoew the 
    ProcessRequest scriptblock is executed and it reverts back the impersonation just after.

.PARAMETER SkipReadingInputstream
    Skip parsing the inputstream. This leaves the inputstream untouched for explicit processing of 
    $request.inputstream.

.EXAMPLE
    "<html><body>Hello</body></html>" | out-file "c:\ps\index.html"
    Invoke-PSIS -URL "http://*:8087/" -AuthenticationSchemes negotiate -ProcessRequest {
        if($Request.rawurl -eq "/index.html"){
            $Response.ResponseFile = "c:\ps\index.html"
        } else {
            $params = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            Write-Verbose "Searching for user: $($params["user"])"
            if($params -and $params["user"]) {
                Get-ADUser -Identity $params["user"]
            }
        }
    } -Verbose -Impersonate -Modules "ActiveDirectory"

    This is an example of binding the webserver to port 8087 with the negotiate (kerberos) authentication scheme.
    The -Verbose switch is used to output messages on the screen for troubleshooting. There is an added property
    to the $response object called ResponseFile. If the $response.ResponseFile property is set to a valid file, then
    PSIS will send the file to the calling agent. Further more, PSIS runs with impersonation enabled. 

    The -Modules parameter specifies modules to be loaded for the runspaces in the internal runspacepool.

    The sample maps /index.html to the c:\ps\index.html file.

    If a URL such as http://servername:8087/?user=administrator is requested then the sample code will extract the 
    administrator value and pass this to Get-ADUser. The returning object will then be JSONified and sent to the 
    calling agent.

.EXAMPLE

    Invoke-PSIS -URL "https://*:443/" -AuthenticationSchemes Basic -ProcessRequest {
        "<html><body>Hello $($user.identity.name)</body></html>"
    } -Verbose 

    Here we bind PSIS to SSL on port 443. AuthenticationScheme is set to basic authentication.
    We use the automatic $user variable to get the WindowsIdentity object and its Name property 
    this gives us the username of the calling user. A certificate needs to be deplyed to the machine in 
    order for this binding to work.

.NOTES

    Hello, my name is Johan Åkerström. I'm the author of PSIS.

    Please visit my blog at:

        http://blog.cosmoskey.com

    If you need to email me then do so on:

        mailto:johan.akerstrom {at} cosmoskey com

    Visit this GitHub project at:

        http://github.com/CosmosKey/PSIS

    Enjoy!

#>
Function Invoke-PSIS {

    [cmdletbinding()]
    param(
        [string]$URL = "http://*:8080/",
        [System.Net.AuthenticationSchemes]$AuthenticationSchemes = "Negotiate",
        [int]$RunspacesCount = 4,
        [scriptblock]$ProcessRequest={},
        [string[]]$Modules,
        [Switch]$SkipReadingInputstream,
        [Switch]$Impersonate
    )

    if($Impersonation -and ($AuthenticationSchemes -eq "none" -or $AuthenticationSchemes -eq "anonymous")){
        throw "Impersonation can't be used with the None or Anonymous authenticationScheme."
    }

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($url)
    $listener.AuthenticationSchemes = $authenticationSchemes
    $listener.Start()

    $InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    $Modules | % {
        if($_){
            [void]$InitialSessionState.ImportPSModule($_)
        }
    }

    Write-Verbose "Starting up a runspace pool of $RunspacesCount runspaces"
    $pool = [runspacefactory]::CreateRunspacePool($InitialSessionState)
    [void]$pool.SetMaxRunspaces($RunspacesCount)
    $pool.Open()

    $VerboseMessageQueue = [System.Collections.Queue]::Synchronized((new-object Collections.Queue))
    $RequestListener = {
        param($config)
        $config.VerboseMessageQueue.Enqueue("Waiting for request")
        $psWorker = [powershell]::Create() # $config.InitialSessionState)
        $config.Context = $config.listener.GetContext()
        $psWorker.RunspacePool = $config.Pool
        [void]$psWorker.AddScript($config.RequestHandler.ToString())
        [void]$psWorker.AddArgument($config)
        [void]$psWorker.BeginInvoke()
    }
    $RequestHandler = {
        param($config)
        Function Write-Verbose {
            param($message)
            $config.VerboseMessageQueue.Enqueue("$message")
        }
        $context = $config.context
        $Request  = $context.Request
        $Response = $context.Response
        $User     = $context.User
        
         
        $clientAddress = "{0}:{1}" -f $Request.RemoteEndPoint.Address,$Request.RemoteEndPoint.Port
        Write-Verbose "Client connecting from $clientAddress"
        if($User.Identity){
            Write-Verbose "User $($User.Identity.Name) sent a request"
        }
        
        if(!$config.SkipReadingInputstream){
            Write-Verbose "Reading request body"
            $length = $Request.ContentLength64
            $buffer = New-Object "byte[]" $length
            [void]$Request.InputStream.Read($buffer,0,$length)
            $requestBody = [System.Text.Encoding]::ASCII.GetString($buffer)
            $requestObject = $requestBody | ConvertFrom-Json
            $context.Request  | Add-Member -Name RequestBody -MemberType NoteProperty -Value $requestBody -Force
            $context.Request  | Add-Member -Name RequestBuffer -MemberType NoteProperty -Value $buffer-Force
            $context.Request  | Add-Member -Name RequestObject -MemberType NoteProperty -Value $requestObject -Force
        }
        $context.Response | Add-Member -Name ResponseFile -MemberType NoteProperty -Value $null -Force
        try {
            if($config.Impersonate){
                $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                Write-Verbose "Impersonate as $($User.Identity.Name) from $currentUser."
                $ImpersonationContext = $User.Identity.Impersonate()
            } 
            $ProcessRequest = [scriptblock]::Create($config.ProcessRequest.tostring())
            Write-Verbose "Executing ProcessRequest"
            $result = .$ProcessRequest $context
            if($context.Response.ResponseFile) {
                Write-Verbose "The ResponseFile property was set"
                Write-Verbose "Sending file $($context.Response.ResponseFile)"
                $buffer = [System.IO.File]::ReadAllBytes($context.Response.ResponseFile)
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            } elseif($context.Response.ContentLength64 -eq 0){
                if($result -ne $null) {
                    if($result -is [string]){
                        Write-Verbose "A [string] object was returned. Writing it directly to the response stream."
                        $buffer = [System.Text.Encoding]::ASCII.GetBytes($result)
                        $response.ContentLength64 = $buffer.Length
                        $response.OutputStream.Write($buffer, 0, $buffer.Length)
                        if(!$response.contenttype) {
                            $response.contenttype = "text/html"
                        }
                    } else {
                        Write-Verbose "Converting PS Objects into JSON objects"
                        $jsonResponse = $result | ConvertTo-Json
                        $buffer = [System.Text.Encoding]::ASCII.GetBytes($jsonResponse)
                        $response.ContentLength64 = $buffer.Length
                        $response.OutputStream.Write($buffer, 0, $buffer.Length)
                        if(!$response.contenttype) {
                            $response.contenttype = "application/json"
                        }
                    }
                }
            }
        } catch {
            $Context.Response.StatusRequestHandler = "500"
        } finally {
            if($config.Impersonate){
                Write-Verbose "Undo impersonation as $($User.Identity.Name) reverting back to $currentUser"
                $ImpersonationContext.Undo()
            } 
            $response.close()
        }

    }
   
    try {
        Write-Verbose "Server listening on $url"
        while ($listener.IsListening)
        {
            if($iasync -eq $null -or $iasync.IsCompleted) {
                $obj = New-Object object
                $ps = [powershell]::Create() # $InitialSessionState)
                $ps.RunspacePool = $pool
                $config = [pscustomobject]@{
                    Listener = $listener
                    Pool = $pool
                    VerboseMessageQueue = $VerboseMessageQueue
                    Requesthandler = $Requesthandler
                    ProcessRequest = $ProcessRequest
                    InitialSessionState = $InitialSessionState
                    Impersonate = $Impersonate
                    Context = $null
                    SkipReadingInputstream = $SkipReadingInputstream
                }
                [void]$ps.AddScript($RequestListener.ToString())
                [void]$ps.AddArgument($config)
                $iasync = $ps.BeginInvoke()
            }
            while($VerboseMessageQueue.count -gt 0){
                Write-Verbose $VerboseMessageQueue.Dequeue()
            }                 
            Start-Sleep -Milliseconds 30
        }
    } finally {
        Write-Verbose "Closing down server"
        $listener.Stop()
        $listener.Close()
    }
}
Export-ModuleMember -Function "Invoke-PSIS"