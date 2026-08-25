#!/usr/bin/env python3
"""
generate_pbxproj.py — regenerates SalmanMacCleaner.xcodeproj/project.pbxproj
from the files actually present on disk. Deterministic IDs; the app target,
test target, scheme-blueprint IDs and build settings remain stable.

Usage:
    python3 Tools/generate_pbxproj.py
"""

from __future__ import annotations

import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_DIR = os.path.join(ROOT, "SalmanMacCleaner")
TEST_DIR = os.path.join(ROOT, "SalmanMacCleanerTests")
PROJECT_DIR = os.path.join(ROOT, "SalmanMacCleaner.xcodeproj")
PBXPROJ = os.path.join(PROJECT_DIR, "project.pbxproj")

# Stable blueprint identifiers (must match the shared scheme).
PROJECT_ID = "300000000000000000000001"
APP_TARGET_ID = "400000000000000000000001"
TEST_TARGET_ID = "400000000000000000000002"

IGNORE_DIRS = {"en.lproj", "Assets.xcassets", "xcuserdata"}
RESOURCE_FILES = {"Assets.xcassets"}
LOCALIZABLE_REL = "SalmanMacCleaner/en.lproj/Localizable.strings"

# Sparkle SPM reference (resolves on macOS hosts with network access).
SPARKLE_REPO = "https://github.com/sparkle-project/Sparkle"
SPARKLE_VERSION = "2.6.0"


def next_id(counter: list) -> str:
    counter[0] += 1
    return f"DD{counter[0]:024d}"


def collect_swift_files() -> tuple[list[str], list[str]]:
    """Returns (app files relative to repo root, test files relative to repo root)."""
    app_files: list[str] = []
    test_files: list[str] = []
    for base, label, out in ((APP_DIR, "app", app_files), (TEST_DIR, "test", test_files)):
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in IGNORE_DIRS]
            for name in sorted(filenames):
                if name.endswith(".swift"):
                    out.append(os.path.relpath(os.path.join(dirpath, name), ROOT))
    return app_files, test_files


def build_pbxproj(app_files: list[str], test_files: list[str]) -> str:
    counter = [0]

    file_refs: dict[str, str] = {}       # rel path -> fileRef id
    build_files: dict[str, str] = {}     # rel path -> buildFile id
    groups: dict[str, str] = {}          # group path key -> group id

    # ---- file references + build files
    fr_entries: list[str] = []
    bf_entries: list[str] = []
    all_swift = app_files + test_files
    for rel in all_swift:
        fr = next_id(counter)
        bf = next_id(counter)
        file_refs[rel] = fr
        build_files[rel] = bf
        fr_entries.append(f'\t\t{fr} /* {os.path.basename(rel)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {os.path.basename(rel)}; sourceTree = "<group>"; }};')
        bf_entries.append(f'\t\t{bf} /* {os.path.basename(rel)} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {os.path.basename(rel)} */; }};')

    # resources
    assets_fr = next_id(counter)
    assets_bf = next_id(counter)
    fr_entries.append(f'\t\t{assets_fr} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
    bf_entries.append(f'\t\t{assets_bf} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_fr} /* Assets.xcassets */; }};')

    loc_fr = next_id(counter)
    loc_bf = next_id(counter)
    fr_entries.append(f'\t\t{loc_fr} /* Localizable.strings */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = Localizable.strings; path = "en.lproj/Localizable.strings"; sourceTree = "<group>"; }};')
    bf_entries.append(f'\t\t{loc_bf} /* Localizable.strings in Resources */ = {{isa = PBXBuildFile; fileRef = {loc_fr} /* Localizable.strings */; }};')

    plist_fr = next_id(counter)
    entitlements_fr = next_id(counter)
    fr_entries.append(f'\t\t{plist_fr} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
    fr_entries.append(f'\t\t{entitlements_fr} /* SalmanMacCleaner.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = SalmanMacCleaner.entitlements; sourceTree = "<group>"; }};')

    app_product_fr = next_id(counter)
    test_product_fr = next_id(counter)
    fr_entries.append(f'\t\t{app_product_fr} /* SalmanMacCleaner.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SalmanMacCleaner.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    fr_entries.append(f'\t\t{test_product_fr} /* SalmanMacCleanerTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = SalmanMacCleanerTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};')

    # ---- group tree
    def group_id(key: str) -> str:
        if key not in groups:
            groups[key] = next_id(counter)
        return groups[key]

    def group_children(rel_dir: str) -> list[str]:
        children: list[str] = []
        subdirs: dict[str, str] = {}
        for rel in all_swift:
            if not rel.startswith(rel_dir):
                continue
            rest = rel[len(rel_dir):].lstrip("/")
            if "/" in rest:
                sub = rest.split("/")[0]
                # Use the same stable path-derived ID as group_entry.  The
                # previous counter-based ID made nested groups collide with
                # unrelated groups and left Xcode looking for files at the
                # repository root instead of inside SalmanMacCleaner/.
                subdirs.setdefault(sub, group_id(rel_dir.rstrip("/") + "/" + sub))
            else:
                children.append(f'{file_refs[rel]} /* {os.path.basename(rel)} */')
        for sub, gid in sorted(subdirs.items()):
            children.append(f'{gid} /* {sub} */')
        return children

    def group_entry(key: str, name: str, path: str, children: list[str]) -> str:
        gid = group_id(key)
        child_lines = "\n".join(f"\t\t\t\t{child}," for child in children)
        return (
            f"\t\t{gid} /* {name} */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n{child_lines}\n"
            f"\t\t\t);\n"
            f"\t\t\tpath = {path};\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};"
        )

    root_gid = next_id(counter)
    app_group_gid = group_id("SalmanMacCleaner")
    test_group_gid = group_id("SalmanMacCleanerTests")
    products_gid = group_id("Products")

    # subgroups under SalmanMacCleaner (mirror directory tree)
    subgroup_entries: list[str] = []
    subdir_set = set()
    for rel in app_files:
        parts = rel.split("/")
        for depth in range(2, len(parts)):
            subdir_set.add("/".join(parts[:depth]))
    for sub in sorted(subdir_set):
        name = sub.split("/")[-1]
        children = group_children(sub + "/")
        subgroup_entries.append(group_entry(sub, name, name, children))

    # app group children: root-level swift files + special files + subgroups
    app_children: list[str] = []
    for rel in app_files:
        parts = rel.split("/")
        if len(parts) == 2:  # SalmanMacCleaner/<file>.swift
            app_children.append(f'{file_refs[rel]} /* {os.path.basename(rel)} */')
    app_children.append(f'{plist_fr} /* Info.plist */')
    app_children.append(f'{entitlements_fr} /* SalmanMacCleaner.entitlements */')
    app_children.append(f'{assets_fr} /* Assets.xcassets */')
    app_children.append(f'{loc_fr} /* Localizable.strings */')
    for sub in sorted(subdir_set):
        if sub.count("/") == 1:
            app_children.append(f'{group_id(sub)} /* {sub.split("/")[-1]} */')

    test_children = [f'{file_refs[rel]} /* {os.path.basename(rel)} */' for rel in test_files]

    group_entries = [
        group_entry("SalmanMacCleaner", "SalmanMacCleaner", "SalmanMacCleaner", app_children),
        group_entry("SalmanMacCleanerTests", "SalmanMacCleanerTests", "SalmanMacCleanerTests", test_children),
        group_entry("Products", "Products", None, [
            f'{app_product_fr} /* SalmanMacCleaner.app */',
            f'{test_product_fr} /* SalmanMacCleanerTests.xctest */',
        ]),
    ]
    # Fix Products group: no path
    group_entries[2] = group_entries[2].replace('\t\t\tpath = None;\n', '').replace(
        'sourceTree = "<group>";', 'name = Products;\n\t\t\tsourceTree = "<group>";'
    )
    group_entries.extend(subgroup_entries)

    root_children = [
        f'{app_group_gid} /* SalmanMacCleaner */',
        f'{test_group_gid} /* SalmanMacCleanerTests */',
        f'{products_gid} /* Products */',
    ]

    # ---- Sparkle package reference
    pkg_ref_id = next_id(counter)
    product_dep_id = next_id(counter)
    pkg_entries = [
        f'\t\t{pkg_ref_id} /* XCRemoteSwiftPackageReference "Sparkle" */ = {{isa = XCRemoteSwiftPackageReference; repositoryURL = "{SPARKLE_REPO}"; requirement = {{kind = upToNextMajorVersion; minimumVersion = {SPARKLE_VERSION};}};}};',
        f'\t\t{product_dep_id} /* Sparkle */ = {{isa = XCSwiftPackageProductDependency; package = {pkg_ref_id} /* XCRemoteSwiftPackageReference "Sparkle" */; productName = Sparkle;}};',
    ]

    # ---- source build phases
    app_sources = "\n".join(f'\t\t\t\t{build_files[rel]} /* {os.path.basename(rel)} in Sources */,' for rel in app_files)
    test_sources = "\n".join(f'\t\t\t\t{build_files[rel]} /* {os.path.basename(rel)} in Sources */,' for rel in test_files)

    # ---- frameworks: app links Sparkle
    frameworks_app = f'\t\t\t\t{product_dep_id} /* Sparkle in Frameworks */,'

    pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(bf_entries)}
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		200000000000000000000001 /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = {PROJECT_ID} /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {APP_TARGET_ID};
			remoteInfo = SalmanMacCleaner;
		}};
/* End PBXContainerItemProxy section */

/* Begin PBXFileReference section */
{chr(10).join(fr_entries)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		500000000000000000000001 /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
{frameworks_app}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		500000000000000000000002 /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{root_gid} = {{
			isa = PBXGroup;
			children = (
				{app_group_gid} /* SalmanMacCleaner */,
				{test_group_gid} /* SalmanMacCleanerTests */,
				{products_gid} /* Products */,
			);
			sourceTree = "<group>";
		}};
{chr(10).join(group_entries)}
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{APP_TARGET_ID} /* SalmanMacCleaner */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = 800000000000000000000002 /* Build configuration list for PBXNativeTarget "SalmanMacCleaner" */;
			buildPhases = (
				500000000000000000000003 /* Sources */,
				500000000000000000000001 /* Frameworks */,
				500000000000000000000005 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = SalmanMacCleaner;
			packageProductDependencies = (
				{product_dep_id} /* Sparkle */,
			);
			productName = SalmanMacCleaner;
			productReference = {app_product_fr} /* SalmanMacCleaner.app */;
			productType = "com.apple.product-type.application";
		}};
		{TEST_TARGET_ID} /* SalmanMacCleanerTests */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = 800000000000000000000003 /* Build configuration list for PBXNativeTarget "SalmanMacCleanerTests" */;
			buildPhases = (
				500000000000000000000004 /* Sources */,
				500000000000000000000002 /* Frameworks */,
				500000000000000000000006 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
				700000000000000000000001 /* PBXTargetDependency */,
			);
			name = SalmanMacCleanerTests;
			productName = SalmanMacCleanerTests;
			productReference = {test_product_fr} /* SalmanMacCleanerTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{PROJECT_ID} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1500;
				LastUpgradeCheck = 1500;
				TargetAttributes = {{
					{APP_TARGET_ID} = {{
						CreatedOnToolsVersion = 15.0;
					}};
					{TEST_TARGET_ID} = {{
						CreatedOnToolsVersion = 15.0;
						TestTargetID = {APP_TARGET_ID};
					}};
				}};
			}};
			buildConfigurationList = 800000000000000000000001 /* Build configuration list for PBXProject "SalmanMacCleaner" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {root_gid};
			packageReferences = (
				{pkg_ref_id} /* XCRemoteSwiftPackageReference "Sparkle" */,
			);
			productRefGroup = {products_gid} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{APP_TARGET_ID} /* SalmanMacCleaner */,
				{TEST_TARGET_ID} /* SalmanMacCleanerTests */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		500000000000000000000005 /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{assets_bf} /* Assets.xcassets in Resources */,
				{loc_bf} /* Localizable.strings in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		500000000000000000000006 /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		500000000000000000000003 /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{app_sources}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		500000000000000000000004 /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{test_sources}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		700000000000000000000001 /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {APP_TARGET_ID} /* SalmanMacCleaner */;
			targetProxy = 200000000000000000000001 /* PBXContainerItemProxy */;
		}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
		A00000000000000000000001 /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				LOCALIZATION_PREFERS_STRING_CATALOGS = YES;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				MTL_FAST_MATH = YES;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		A00000000000000000000002 /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				LOCALIZATION_PREFERS_STRING_CATALOGS = YES;
				MTL_ENABLE_DEBUG_INFO = NO;
				MTL_FAST_MATH = YES;
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
			}};
			name = Release;
		}};
		A00000000000000000000003 /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_ENTITLEMENTS = SalmanMacCleaner/SalmanMacCleaner.entitlements;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_APP_SANDBOX = YES;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = SalmanMacCleaner/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				MARKETING_VERSION = 1.1.1;
				PRODUCT_BUNDLE_IDENTIFIER = com.salman.SalmanMacCleaner;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.9;
			}};
			name = Debug;
		}};
		A00000000000000000000004 /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_ENTITLEMENTS = SalmanMacCleaner/SalmanMacCleaner.entitlements;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_APP_SANDBOX = YES;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = SalmanMacCleaner/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				MARKETING_VERSION = 1.1.1;
				PRODUCT_BUNDLE_IDENTIFIER = com.salman.SalmanMacCleaner;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.9;
			}};
			name = Release;
		}};
		A00000000000000000000005 /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				GENERATE_INFOPLIST_FILE = YES;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				MARKETING_VERSION = 1.1.1;
				PRODUCT_BUNDLE_IDENTIFIER = com.salman.SalmanMacCleanerTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.9;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/SalmanMacCleaner.app/Contents/MacOS/SalmanMacCleaner";
			}};
			name = Debug;
		}};
		A00000000000000000000006 /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				BUNDLE_LOADER = "$(TEST_HOST)";
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				GENERATE_INFOPLIST_FILE = YES;
				MACOSX_DEPLOYMENT_TARGET = 13.0;
				MARKETING_VERSION = 1.1.1;
				PRODUCT_BUNDLE_IDENTIFIER = com.salman.SalmanMacCleanerTests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 5.9;
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/SalmanMacCleaner.app/Contents/MacOS/SalmanMacCleaner";
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		800000000000000000000001 /* Build configuration list for PBXProject "SalmanMacCleaner" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				A00000000000000000000001 /* Debug */,
				A00000000000000000000002 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		800000000000000000000002 /* Build configuration list for PBXNativeTarget "SalmanMacCleaner" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				A00000000000000000000003 /* Debug */,
				A00000000000000000000004 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		800000000000000000000003 /* Build configuration list for PBXNativeTarget "SalmanMacCleanerTests" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				A00000000000000000000005 /* Debug */,
				A00000000000000000000006 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {PROJECT_ID} /* Project object */;
}}
"""
    return pbx


def main() -> int:
    app_files, test_files = collect_swift_files()
    print(f"app files: {len(app_files)}, test files: {len(test_files)}")
    pbx = build_pbxproj(app_files, test_files)
    with open(PBXPROJ, "w", encoding="utf-8") as handle:
        handle.write(pbx)
    print(f"wrote {PBXPROJ}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
