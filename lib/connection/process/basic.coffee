net = require 'net'
child_process = require 'child_process'

{paths} = require '../../misc'
client = require '../client'

module.exports =

  freePort: ->
    new Promise (resolve) ->
      server = net.createServer()
      server.listen 0, '127.0.0.1', ->
        port = server.address().port
        server.close()
        resolve port

  createProc: (proc, obj = {}) ->
    obj.onExit = (f) ->
      proc.on 'exit', f
      {dispose: -> proc.removeListener('exit', f)}
    obj.stdin ?= proc.stdin
    obj.stdout ?= proc.stdout
    obj.stderr ?= proc.stderr
    obj

  socket: (proc, port) ->
    new Promise (resolve, reject) ->
      proc.stderr.on 'data', f = (data) ->
        if data.toString() == 'juno-msg-ready'
          proc.stderr.removeListener 'data', f
          resolve net.connect port
      proc.on 'exit', (code, status) ->
        reject [code, status]

  getUnix: (path, args) ->
    @freePort().then (port) =>
      proc = child_process.spawn path, [args..., paths.script('boot.jl'), port]

      @createProc proc,
        kill: -> proc.kill()
        interrupt: -> proc.kill 'SIGINT'
        socket: @socket proc, port

  # Windows Stuff

  sendSignalToWrapper: (signal, port) ->
    wrapper = net.connect({port})
    wrapper.setNoDelay()
    wrapper.write(signal)
    wrapper.end()

  getWindows: (path, args) ->
    useWrapper = atom.config.get "julia-client.enablePowershellWrapper"
    powershell = parseInt(child_process.spawnSync("powershell",
                                                  ["-NoProfile", "$PSVersionTable.PSVersion.Major"])
                            .output[1].toString()) > 2
    if !(useWrapper && powershell)
      if not powershell
        client.stderr "PowerShell version < 3 encountered. Running without wrapper (interrupts won't work)."
      @getUnix path, args
    else
      @freePort().then (port) =>
        wrapPort = port+1
        jlargs = [args..., '`"' + paths.script('boot.jl') + '`"', port]
        proc = child_process.spawn("powershell",
                                    ["-NoProfile", "-ExecutionPolicy", "bypass",
                                     "& \"#{paths.script "spawnInterruptible.ps1"}\"
                                     -wrapPort #{wrapPort}
                                     -jlpath \"#{path}\"
                                     -jlargs #{jlargs}"])

        @createProc proc,
          wrapper: true
          kill: => @sendSignalToWrapper 'KILL', wrapPort
          interrupt: => @sendSignalToWrapper 'SIGINT', wrapPort
          socket: @socket proc, port

  get: (a...) ->
    if process.platform is 'win32'
      @getWindows a...
    else
      @getUnix a...
