#!/usr/bin/env python3
"""Dependency-free, deterministic Xcode project generation. No source files overwritten."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parent.parent
uid = lambda s: hashlib.sha1(s.encode()).hexdigest()[:24].upper()
objects = []
def obj(key, text):
    objects.append(f'{uid(key)} = {{ {text} }};')
    return uid(key)
sources = sorted((root / 'Otolog').glob('*.swift'))
refs, builds = [], []
for path in sources:
    ref = obj(path.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {path.name}; sourceTree = "<group>";')
    refs.append(ref)
    builds.append(obj('build'+path.name, f'isa = PBXBuildFile; fileRef = {ref};'))
app = obj('app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Otolog.app; sourceTree = BUILT_PRODUCTS_DIR;')
sg = obj('sourcegroup', f'isa = PBXGroup; children = ({",".join(refs)},); path = Otolog; sourceTree = "<group>";')
pg = obj('products', f'isa = PBXGroup; children = ({app},); name = Products; sourceTree = "<group>";')
main = obj('main', f'isa = PBXGroup; children = ({sg},{pg},); sourceTree = "<group>";')
phase = obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
frameworks = obj('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
configs = []
for name in ['Debug','Release']:
    settings = '''ALWAYS_SEARCH_USER_PATHS = NO; SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; SWIFT_VERSION = 5.0; PRODUCT_NAME = Otolog; PRODUCT_BUNDLE_IDENTIFIER = local.tetsugo.MeetingRecorder; INFOPLIST_FILE = Otolog/Info.plist; CODE_SIGN_ENTITLEMENTS = Otolog/Otolog.entitlements; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; ENABLE_HARDENED_RUNTIME = YES; ENABLE_APP_SANDBOX = NO; SWIFT_STRICT_CONCURRENCY = targeted; COMBINE_HIDPI_IMAGES = YES; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";'''
    settings += ' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf;' if name == 'Debug' else ' SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
    configs.append(obj('config'+name, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ {settings} }};'))
configlist = obj('configs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {configlist}; buildPhases = ({phase},{frameworks},); buildRules = (); dependencies = (); name = Otolog; productName = Otolog; productReference = {app}; productType = "com.apple.product-type.application";')
project = obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2710; }}; buildConfigurationList = {configlist}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ja; knownRegions = (ja,en,Base); mainGroup = {main}; productRefGroup = {pg}; projectDirPath = ""; projectRoot = ""; targets = ({target},);')
(root/'Otolog.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
scheme = root/'Otolog.xcodeproj/xcshareddata/xcschemes'
scheme.mkdir(parents=True, exist_ok=True)
buildref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Otolog.app" BlueprintName="Otolog" ReferencedContainer="container:Otolog.xcodeproj"/>'
(scheme/'Otolog.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildref}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated Otolog.xcodeproj')
