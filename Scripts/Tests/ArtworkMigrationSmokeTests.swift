// Copyright (c) 2026, OpenEmu Team
// SPDX-License-Identifier: BSD-3-Clause

import Cocoa

// Only the surrounding database is substituted. The compiled OEDBImage file,
// conversion, disk reads/writes and asynchronous UI getter are production code.
@objcMembers
class OEDBItem: NSManagedObject {
    class var entityName: String { "" }
    var libraryDatabase: OELibraryDatabase! { OELibraryDatabase.default }
    class func createObject(in context: NSManagedObjectContext) -> Self {
        NSEntityDescription.insertNewObject(forEntityName: entityName, into: context) as! Self
    }
    @discardableResult
    func save() -> Bool {
        do { try managedObjectContext?.save(); return true }
        catch { return false }
    }
}

@objc class OEDBGame: NSManagedObject {}

@objcMembers
final class OELibraryDatabase: NSObject {
    static var `default`: OELibraryDatabase?
    let coverFolderURL: URL
    let mainThreadContext: NSManagedObjectContext
    init(folder: URL, context: NSManagedObjectContext) {
        coverFolderURL = folder
        mainThreadContext = context
    }
}

func DLog(_ message: String) { print(message) }

@main
private struct ArtworkMigrationSmokeTests {
    static func main() throws {
        precondition(CommandLine.arguments.count == 2 ||
                     (CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--expect-cold-cache-regression"))
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manager = FileManager.default
        precondition(root.path.hasPrefix("/private/tmp/openemu-artwork-migration-"))
        let initialFiles = try manager.contentsOfDirectory(atPath: root.path)
        precondition(initialFiles.isEmpty)

        let entity = NSEntityDescription()
        entity.name = "Image"
        entity.managedObjectClassName = NSStringFromClass(OEDBImage.self)
        entity.properties = [
            attribute("format", .integer64AttributeType),
            attribute("height", .floatAttributeType),
            attribute("width", .floatAttributeType),
            attribute("relativePath", .stringAttributeType),
            attribute("source", .stringAttributeType),
        ]
        let game = NSEntityDescription()
        game.name = "Game"
        game.managedObjectClassName = NSStringFromClass(OEDBGame.self)
        let box = NSRelationshipDescription()
        box.name = "Box"
        box.destinationEntity = game
        box.minCount = 0
        box.maxCount = 1
        box.isOptional = true
        entity.properties.append(box)
        let model = NSManagedObjectModel()
        model.entities = [entity, game]
        let store = NSPersistentStoreCoordinator(managedObjectModel: model)
        try store.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = store
        OELibraryDatabase.default = OELibraryDatabase(folder: root, context: context)

        func record(_ name: String?) -> OEDBImage {
            let image = OEDBImage(entity: entity, insertInto: context)
            image.relativePath = name
            image.format = -1
            image.width = 4
            image.height = 4
            return image
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 16, bitsPerPixel: 32)!
        bitmap.bitmapData!.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = bitmap.representation(using: .png, properties: [:])!

        // No warm-up read: this is exactly how the old-format migration starts.
        let coldURL = root.appendingPathComponent("legacy.png")
        try png.write(to: coldURL)
        let cold = record(coldURL.lastPathComponent)
        let converted = cold.convert(to: .jpeg, withProperties: [.compressionFactor: 0.9])
        if CommandLine.arguments.count == 3 {
            precondition(!converted && manager.fileExists(atPath: coldURL.path),
                         "The baseline must reproduce the old cold-cache conversion failure")
            print("REPRODUCED: old async getter rejects valid cold-cache artwork during migration")
            return
        }
        precondition(converted,
                     "A cold-cache valid artwork must convert instead of being treated as corrupt")
        precondition(cold.format.intValue == Int(NSBitmapImageRep.FileType.jpeg.rawValue))
        precondition(cold.relativePath != coldURL.lastPathComponent)
        precondition(!manager.fileExists(atPath: coldURL.path))
        precondition(cold.loadImageSynchronously()?.isValid == true)
        print("PASS: cold-cache legacy artwork converts and its replacement remains readable")

        let visibleURL = root.appendingPathComponent("visible.png")
        try png.write(to: visibleURL)
        let visible = record(visibleURL.lastPathComponent)
        precondition(visible.image == nil, "The UI path should remain asynchronous on a cold cache")
        precondition(visible.loadImageSynchronously()?.isValid == true,
                     "An integrity read must not mistake a pending UI decode for invalid artwork")
        let deadline = Date().addingTimeInterval(5)
        while visible.image == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(visible.image?.isValid == true)
        print("PASS: UI decode remains asynchronous; synchronous integrity checks are definitive")

        let invalidURL = root.appendingPathComponent("invalid.png")
        let invalidBytes = Data("not an image".utf8)
        try invalidBytes.write(to: invalidURL)
        let invalid = record(invalidURL.lastPathComponent)
        precondition(invalid.loadImageSynchronously() == nil)
        precondition(!invalid.convert(to: .jpeg, withProperties: [:]))
        let remainingInvalidBytes = try Data(contentsOf: invalidURL)
        precondition(remainingInvalidBytes == invalidBytes)
        precondition(invalid.relativePath == invalidURL.lastPathComponent && invalid.format == -1)
        print("PASS: corrupt artwork fails conversion without modifying the source")

        let missing = record("missing.png")
        precondition(missing.loadImageSynchronously() == nil)
        precondition(!missing.convert(to: .jpeg, withProperties: [:]))
        precondition(!manager.fileExists(atPath: root.appendingPathComponent("missing.png").path))
        let noPath = record(nil)
        precondition(noPath.loadImageSynchronously() == nil)
        precondition(!noPath.convert(to: .jpeg, withProperties: [:]))
        print("PASS: missing/pathless artwork fails without creating files")
    }

    private static func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
        let value = NSAttributeDescription()
        value.name = name
        value.attributeType = type
        value.isOptional = true
        return value
    }
}
