// hello.groovy - smoke test for lm-collector-run-groovy.ps1
//
// Prints basic collector/runtime info so you can confirm the runner surfaces
// stdout end to end. Self-contained: needs no device context (no hostProps),
// so it is safe to run on any collector.
//
//   ./lm-collector-run-groovy.ps1 -Script hello.groovy -Collector <id|name>

println "hello from the collector"
println "host:    " + java.net.InetAddress.getLocalHost().getHostName()
println "time:    " + new Date()
println "java:    " + System.getProperty("java.version")
println "os:      " + System.getProperty("os.name") + " (" + System.getProperty("os.arch") + ")"
println "user:    " + System.getProperty("user.name")
println "cwd:     " + System.getProperty("user.dir")

return 0
