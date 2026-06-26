// dump-hostprops.groovy - diagnostic for lm-collector-run-groovy.ps1 -WithHostProps
//
// Tells you (a) whether hostProps loaded and how many entries, (b) whether it is reachable
// from the script's MAIN body, and (c) whether it is reachable from inside a METHOD - which
// is what scripts like the credential check need (their printprop helper reads hostProps).
// Values are the collector's real ones. Caution: output can contain sensitive values in clear
// text; run with -OutputDir to a file you control:
//
//   ./lm-collector-run-groovy.ps1 -Script dump-hostprops.groovy -Device <name> -WithHostProps -OutputDir /tmp

// (c) method access - mirrors how the credential check uses hostProps
def sizeFromMethod() {
    try { return "method sees hostProps: " + hostProps.size() + " entries" }
    catch (Throwable t) { return "method CANNOT see hostProps: " + t.class.simpleName + " - " + t.message }
}

// (b) main-body access
try {
    println "main sees hostProps: " + hostProps.size() + " entries"
} catch (Throwable t) {
    println "main CANNOT see hostProps: " + t.class.simpleName + " - " + t.message
}

println sizeFromMethod()

// (a) a couple of sample lookups
try {
    println "snmp.community = " + hostProps.get("snmp.community")
    println "system.hostname = " + hostProps.get("system.hostname")
    println "--- all keys ---"
    // hostProps is a com.santaba ParamMap, not a java.util.Map, so Groovy's Map .sort()/.each
    // do not apply - enumerate via keySet() instead.
    (hostProps.keySet() as List).sort().each { k -> println "  ${k} = " + hostProps.get(k) }
} catch (Throwable t) {
    println "key enumeration failed: " + t.class.simpleName + " - " + t.message
}

return 0
