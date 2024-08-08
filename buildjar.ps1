$CLANG_FORMAT = "clang-format-11"
$libzt = Get-Location

$CMAKE = "cmake3"
if (-not (Get-Command $CMAKE -ErrorAction SilentlyContinue)) {
    $CMAKE = "cmake"
}
if (-not (Get-Command $CMAKE -ErrorAction SilentlyContinue)) {
    Write-Output "CMake (cmake) not found. Please install before continuing."
    exit
}

$TREE = "tree"
if (-not (Get-Command $TREE -ErrorAction SilentlyContinue)) {
    $TREE = "du -a"
}

$OSNAME = [System.Environment]::OSVersion.Platform
if ($OSNAME -eq [System.PlatformID]::MacOSX) {
    $SHARED_LIB_NAME = "libzt.dylib"
    $STATIC_LIB_NAME = "libzt.a"
    $HOST_PLATFORM = "macos"
}
elseif ($OSNAME -eq [System.PlatformID]::Unix) {
    $SHARED_LIB_NAME = "libzt.so"
    $STATIC_LIB_NAME = "libzt.a"
    $HOST_PLATFORM = "linux"
}

$HOST_MACHINE_TYPE = [System.Environment]::Is64BitOperatingSystem ? "x64" : "x86"

if ($OSNAME -eq [System.PlatformID]::MacOSX) {
    $N_PROCESSORS = (sysctl -n hw.ncpu)
}
elseif ($OSNAME -eq [System.PlatformID]::Unix) {
    $N_PROCESSORS = (nproc --all)
}

$CMAKE_VERSION = (& $CMAKE --version | Select-Object -First 1 | ForEach-Object { $_ -replace '[^0-9]', '' })
function Ver($version) {
    return [int]::Parse(($version -replace '\.', '') -PadLeft(8, '0'))
}
$BUILD_CONCURRENCY = ""
if (Ver $CMAKE_VERSION -gt Ver "3.12") {
    $BUILD_CONCURRENCY = "-j $N_PROCESSORS"
}

$BUILD_OUTPUT_DIR = (Get-Location).Path + "\dist"
$BUILD_CACHE_DIR = (Get-Location).Path + "\cache"
$PKG_DIR = (Get-Location).Path + "\pkg"
$DEFAULT_HOST_LIB_OUTPUT_DIR = "$BUILD_OUTPUT_DIR\$HOST_PLATFORM-$HOST_MACHINE_TYPE"
$DEFAULT_HOST_BIN_OUTPUT_DIR = "$BUILD_OUTPUT_DIR\$HOST_PLATFORM-$HOST_MACHINE_TYPE"
$DEFAULT_HOST_PKG_OUTPUT_DIR = "$BUILD_OUTPUT_DIR\$HOST_PLATFORM-$HOST_MACHINE_TYPE"
$DEFAULT_HOST_BUILD_CACHE_DIR = "$BUILD_CACHE_DIR\$HOST_PLATFORM-$HOST_MACHINE_TYPE"

function Host-Jar {
    param (
        [string]$BuildType = "release",
        [string]$Test = ""
    )

    $ARTIFACT = "jar"
    $PKG_VERSION = (& git describe --tags --abbrev=0)
    if ($BuildType -like "*docs*") {
        & "$env:JAVA_HOME/bin/javadoc" src/bindings/java/com/zerotier/sockets/*.java -d docs/java
        exit 0
    }
    $VARIANT = "-DZTS_ENABLE_JAVA=True"
    $CACHE_DIR = "$DEFAULT_HOST_BUILD_CACHE_DIR-$ARTIFACT-$BuildType"
    $TARGET_BUILD_DIR = "$DEFAULT_HOST_BIN_OUTPUT_DIR-$ARTIFACT-$BuildType"
    Remove-Item -Recurse -Force $TARGET_BUILD_DIR
    $PKG_OUTPUT_DIR = "$TARGET_BUILD_DIR/pkg"
    New-Item -ItemType Directory -Path $PKG_OUTPUT_DIR -Force
    $JAVA_JAR_DIR = "$CACHE_DIR/pkg/jar"
    $JAVA_JAR_SOURCE_TREE_DIR = "$JAVA_JAR_DIR/com/zerotier/sockets/"
    New-Item -ItemType Directory -Path $JAVA_JAR_SOURCE_TREE_DIR -Force
    Copy-Item -Force src/bindings/java/com/zerotier/sockets/*.java $JAVA_JAR_SOURCE_TREE_DIR
    & $CMAKE $VARIANT -H. -B$CACHE_DIR -DCMAKE_BUILD_TYPE=$BuildType
    & $CMAKE --build $CACHE_DIR $BUILD_CONCURRENCY
    Copy-Item -Force "$CACHE_DIR/lib/libzt.*" $JAVA_JAR_DIR
    Push-Location $JAVA_JAR_DIR
    $env:JAVA_TOOL_OPTIONS = "-Dfile.encoding=UTF8"
    & "$env:JAVA_HOME/bin/javac" -Xlint:all com/zerotier/sockets/*.java
    & "$env:JAVA_HOME/bin/jar" cf "libzt-$PKG_VERSION.jar" $SHARED_LIB_NAME com/zerotier/sockets/*.class
    Remove-Item -Recurse -Force com $SHARED_LIB_NAME
    Pop-Location
    Write-Output "`nContents of JAR:`n"
    & "$env:JAVA_HOME/bin/jar" tf "$JAVA_JAR_DIR/*.jar"
    Write-Output "`n"
    Move-Item -Force "$JAVA_JAR_DIR/*.jar" $PKG_OUTPUT_DIR
    Write-Output "`n - Build cache  : $CACHE_DIR`n - Build output : $BUILD_OUTPUT_DIR`n"
    & $TREE $TARGET_BUILD_DIR

    # Test JAR
    if ($Test -like "*test*") {
        if (-not $env:alice_path) {
            Write-Output "Please set necessary environment variables for test"
            exit 0
        }
        Push-Location test
        Remove-Item -Recurse -Force *.dylib
        Remove-Item -Recurse -Force *.jar
        Copy-Item -Force "$PKG_OUTPUT_DIR/*.jar" .
        & "$env:JAVA_HOME/bin/jar" xf *.jar $SHARED_LIB_NAME
        & "$env:JAVA_HOME/bin/javac" -cp *.jar selftest.java
        Start-Process -FilePath "$env:JAVA_HOME/bin/java" -ArgumentList "-cp .:libzt-$PKG_VERSION.jar selftest server $env:alice_path $env:testnet $env:port4" -PassThru
        Start-Process -FilePath "$env:JAVA_HOME/bin/java" -ArgumentList "-cp .:libzt-$PKG_VERSION.jar selftest client $env:bob_path $env:testnet $env:alice_ip4 $env:port4" -PassThru
        Pop-Location
    }
}
