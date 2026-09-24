// ROM-free integration test of the production, already-built libretro bridge.
#import <Foundation/Foundation.h>
#import <OpenEmuBase/OEGameCoreController.h>
#import <OpenEmuBase/OELibretroCoreTranslator.h>
#import <OpenEmuBase/OEStoragePaths.h>
#include "libretro.h"

static void require(BOOL value, NSString *message) {
    if (!value) { NSLog(@"FAIL %@", message); exit(1); }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        require(argc == 2, @"Pass an explicit private test directory");
        NSString *path = @(argv[1]);
        require([path hasPrefix:@"/private/tmp/openemu-libretro-fixture."], @"Private workspace required");
        NSURL *root = [NSURL fileURLWithPath:path isDirectory:YES];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *error = nil;
        NSURL *profile = [root URLByAppendingPathComponent:@"Profile"];
        require([fm createDirectoryAtURL:profile withIntermediateDirectories:NO attributes:nil error:&error], error.description);
        require([OEStoragePaths configureWithDataRootURL:profile error:&error], error.description);
        root = [OEStoragePaths.dataRootURL URLByDeletingLastPathComponent];
        NSURL *dylib = [root URLByAppendingPathComponent:@"fixture_libretro.dylib"];
        require([[OELibretroCoreTranslator libraryVersionForCoreAtURL:dylib] isEqualToString:@"fixture-1"], @"Probe external libretro ABI/version");
        require([OELibretroCoreTranslator libraryVersionForCoreAtURL:[root URLByAppendingPathComponent:@"absent.dylib"]] == nil, @"Missing external file must not load");

        NSURL *plugin = [root URLByAppendingPathComponent:@"Fixture-RetroArch.oecoreplugin"];
        NSURL *contents = [plugin URLByAppendingPathComponent:@"Contents"];
        require([fm createDirectoryAtURL:contents withIntermediateDirectories:YES attributes:nil error:&error], error.description);
        NSDictionary *info = @{@"CFBundleIdentifier": @"org.openemu.tests.Fixture-RetroArch",
                              @"CFBundleExecutable": @"Fixture-RetroArch", @"CFBundlePackageType": @"BNDL",
                              @"OEGameCoreClass": @"OELibretroCoreTranslator", @"OEGameCorePlayerCount": @2,
                              @"OELibretroCorePath": dylib.path,
                              @"OESystemIdentifiers": @[@"openemu.system.nes", @"openemu.system.nds"]};
        require([info writeToURL:[contents URLByAppendingPathComponent:@"Info.plist"] error:&error], error.description);
        NSBundle *bundle = [NSBundle bundleWithURL:plugin];
        require(bundle != nil, @"Fixture bundle metadata must load");
        OEGameCoreController *controller = [[OEGameCoreController alloc] initWithBundle:bundle];
        NSURL *rom = [root URLByAppendingPathComponent:@"synthetic.dat"];
        require([[@"fixture, not a game" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:rom options:0 error:&error], error.description);
        NSURL *battery = [controller.supportDirectory URLByAppendingPathComponent:@"Battery Saves/synthetic.sav"];

        for (NSString *system in info[@"OESystemIdentifiers"]) {
            @autoreleasepool {
                OELibretroCoreTranslator *core = (id)[controller newGameCore];
                require([core isKindOfClass:OELibretroCoreTranslator.class], @"Controller must select the real bridge");
                // The helper attaches the controller after construction in the app.
                core.owner = controller;
                core.systemIdentifier = system;
                require([core loadFileAtPath:rom.path error:&error], error.description);
                NSData *initial = [core serializeStateWithError:&error];
                require(initial.length == 8, @"External core serialization callbacks");
                const unsigned char *paths = initial.bytes;
                require(paths[4] && paths[5] && paths[6], [NSString stringWithFormat:@"Chosen profile paths: BIOS=%u battery=%u content=%u", paths[4], paths[5], paths[6]]);
                if ([fm fileExistsAtPath:battery.path]) {
                    require([initial isEqualToData:[NSData dataWithContentsOfURL:battery]], @"Battery data restored through the real bridge");
                }
                [core receiveLibretroButton:RETRO_DEVICE_ID_JOYPAD_A forPort:0 pressed:YES];
                [core receiveLibretroButton:RETRO_DEVICE_ID_JOYPAD_B forPort:1 pressed:YES];
                [core receiveLibretroAnalogIndex:RETRO_DEVICE_INDEX_ANALOG_LEFT axis:RETRO_DEVICE_ID_ANALOG_X value:16384 forPort:0];
                [core executeFrame];
                NSData *pressed = [core serializeStateWithError:&error];
                require(pressed.length == 8, @"State size after frame");
                const unsigned char *values = pressed.bytes;
                require(values[1] == 1 && values[2] == 1 && values[3] == 1, @"Two players and analog input reach external callbacks");
                [core receiveLibretroButton:RETRO_DEVICE_ID_JOYPAD_A forPort:0 pressed:NO];
                [core executeFrame];
                NSData *released = [core serializeStateWithError:&error];
                require(((const unsigned char *)released.bytes)[1] == 0, @"Input release reaches external callback");
                require([core deserializeState:pressed withError:&error], @"Restore external save state");
                require([[core serializeStateWithError:&error] isEqualToData:pressed], @"State round trip");
                require(![core deserializeState:[NSData data] withError:&error], @"Reject invalid state");
                [core stopEmulation];
                require([[NSData dataWithContentsOfURL:battery] isEqualToData:pressed], @"Battery data persisted before external core unload");
                NSLog(@"PASS %@ synthetic bridge input/state/battery lifecycle", system);
            }
        }
        NSLog(@"PASS production bridge %@ from %@; no game compatibility claim", OELibretroBridgeVersion,
              [NSBundle bundleForClass:OELibretroCoreTranslator.class].bundlePath);
    }
    return 0;
}
