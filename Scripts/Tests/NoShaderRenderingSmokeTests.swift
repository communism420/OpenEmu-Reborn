// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

import Darwin
import Foundation
import Metal
import OpenEmuShaders

// Offscreen tests of the real, already-built shared renderer. No application,
// emulator, ROM, settings store or user data folder is opened by this executable.
@main
@MainActor
enum NoShaderRenderingSmokeTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    static func requirePixels(_ actual: [UInt8], _ expected: [UInt8],
                              _ label: String, tolerance: Int = 0) throws {
        try require(actual.count == expected.count, "\(label): pixel buffer length differs")
        for index in actual.indices where abs(Int(actual[index]) - Int(expected[index])) > tolerance {
            throw Failure("\(label): byte \(index), got \(actual[index]), expected \(expected[index]) " +
                          "(tolerance \(tolerance)); actual BGRA = \(actual)")
        }
        print("PASS: \(label)")
    }

    static func sourceTexture(_ device: MTLDevice, bytes: [UInt8]) throws -> MTLTexture {
        try require(bytes.count == 16, "The private source fixture must contain four BGRA pixels")
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared
        // The renderer can reuse a same-sized source texture for its independent
        // color-adjustment prepass, so permit its ordinary render-target usage.
        descriptor.usage = [.shaderRead, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Failure("Cannot allocate source texture")
        }
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: 8)
        }
        return texture
    }

    static func render(_ chain: FilterChain, device: MTLDevice, queue: MTLCommandQueue,
                       source: MTLTexture, width: Int = 2, height: Int = 2,
                       sourceOrigin: CGPoint = .zero, aspect: CGSize = CGSize(width: 2, height: 2),
                       flip: Bool = false) throws -> [UInt8] {
        // Core renderers supply an already-cropped texture. A nonzero original
        // screen origin must not crop it a second time in the shared filter chain.
        chain.setSourceRect(CGRect(origin: sourceOrigin, size: CGSize(width: 2, height: 2)), aspect: aspect)
        chain.drawableSize = CGSize(width: width, height: height)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        let rowStride = ((width * 4 + 255) / 256) * 256
        guard let target = device.makeTexture(descriptor: descriptor),
              let readback = device.makeBuffer(length: rowStride * height, options: .storageModeShared),
              let commands = queue.makeCommandBuffer() else {
            throw Failure("Cannot allocate offscreen render/readback resources")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        chain.render(sourceTexture: source, commandBuffer: commands,
                     renderPassDescriptor: pass, flipVertically: flip)
        guard let blit = commands.makeBlitCommandEncoder() else {
            throw Failure("Cannot create GPU readback encoder")
        }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: readback, destinationOffset: 0, destinationBytesPerRow: rowStride,
                  destinationBytesPerImage: rowStride * height)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        try require(commands.status == .completed && commands.error == nil,
                    "GPU render failed: \(String(describing: commands.error))")
        let bytes = readback.contents().assumingMemoryBound(to: UInt8.self)
        return (0..<height).flatMap { row in
            Array(UnsafeBufferPointer(start: bytes.advanced(by: row * rowStride), count: width * 4))
        }
    }

    static func scaled(_ source: [UInt8], scaleX: Int, scaleY: Int, flip: Bool = false) -> [UInt8] {
        (0..<(2 * scaleY)).flatMap { y in
            (0..<(2 * scaleX)).flatMap { x in
                let sourceY = flip ? 1 - y / scaleY : y / scaleY
                let offset = (sourceY * 2 + x / scaleX) * 4
                return Array(source[offset..<(offset + 4)])
            }
        }
    }

    static func adjusted(_ source: [UInt8], gamma: Double, saturation: Double) -> [UInt8] {
        stride(from: 0, to: source.count, by: 4).flatMap { offset in
            let bgr = (0..<3).map { pow(Double(source[offset + $0]) / 255, 1 / gamma) }
            let luma = bgr[2] * 0.2126 + bgr[1] * 0.7152 + bgr[0] * 0.0722
            return bgr.map { UInt8(max(0, min(255, ((luma + ($0 - luma) * saturation) * 255).rounded()))) } + [255]
        }
    }

    static func makeEffect(in workspace: URL) throws -> URL {
        let preset = workspace.appendingPathComponent("Invert.slangp")
        try "shaders = 1\nshader0 = Invert.slang\nfilter_linear0 = false\n".write(to: preset,
                                                                                 atomically: true, encoding: .utf8)
        // A deterministic test effect makes stale passes visible: each RGB
        // channel is inverted. This fixture is not installed as a user shader.
        try """
        #version 450
        layout(std140, set = 0, binding = 0) uniform UBO { mat4 MVP; } global;
        #pragma stage vertex
        layout(location = 0) in vec4 Position;
        layout(location = 1) in vec2 TexCoord;
        layout(location = 0) out vec2 vTexCoord;
        void main() {
            gl_Position = global.MVP * Position;
            vTexCoord = TexCoord;
        }
        #pragma stage fragment
        layout(location = 0) in vec2 vTexCoord;
        layout(location = 0) out vec4 FragColor;
        layout(set = 0, binding = 2) uniform sampler2D Source;
        void main() {
            FragColor = vec4(1.0 - texture(Source, vTexCoord).rgb, 1.0);
        }
        """.write(to: workspace.appendingPathComponent("Invert.slang"), atomically: true, encoding: .utf8)
        return preset
    }

    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    static func run() throws {
        guard CommandLine.arguments.count == 3 else {
            throw Failure("Usage: no-shader-rendering-tests <No Shader.slangp> <private empty fixture directory>")
        }
        let preset = URL(fileURLWithPath: CommandLine.arguments[1])
        let workspace = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let fixtureContents = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
        try require(fixtureContents.isEmpty,
                    "The fixture directory must exist and be empty")
        let options = ShaderCompilerOptions()
        options.languageVersion = .version2_4
        options.isCacheDisabled = true
        options.cacheDir = workspace.appendingPathComponent("ShaderCache", isDirectory: true)
        let zero = try SlangShader(fromURL: preset)
        try require(zero.passes.isEmpty && zero.parameters.isEmpty && zero.luts.isEmpty,
                    "No Shader must contain zero effect passes, parameters and LUTs")
        let compiled = try ShaderPassCompiler(shaderModel: zero).compile(options: options)
        try require(compiled.passes.isEmpty && compiled.parameters.isEmpty && compiled.luts.isEmpty &&
                    compiled.historyCount == 0, "Compiled No Shader must not add effect passes or history")
        print("PASS: bundled No Shader parses and compiles to zero effect passes, LUTs and history")
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure("No Metal device/queue available; run on a Mac with GPU access (not a restricted sandbox)")
        }
        print("Metal device: \(device.name)")
        print("Renderer: \(Bundle(for: SlangShader.self).bundleURL.path)")
        print("Preset: \(preset.path)")
        let chain = try FilterChain(device: device)
        let colors: [UInt8] = [0, 0, 255, 255, 0, 255, 0, 255,
                               255, 0, 0, 255, 255, 255, 255, 255]
        let source = try sourceTexture(device, bytes: colors)
        try chain.setShader(fromURL: preset, options: options)
        try requirePixels(render(chain, device: device, queue: queue, source: source), colors,
                          "zero-pass neutral output preserves original pixels exactly")
        try requirePixels(render(chain, device: device, queue: queue, source: source, width: 4, height: 4),
                          scaled(colors, scaleX: 2, scaleY: 2), "nearest integer scaling has no blended pixels")
        try requirePixels(render(chain, device: device, queue: queue, source: source, flip: true),
                          scaled(colors, scaleX: 1, scaleY: 1, flip: true), "vertical flip preserves pixel values")
        try requirePixels(render(chain, device: device, queue: queue, source: source,
                                 sourceOrigin: CGPoint(x: 3, y: 5)), colors,
                          "already-cropped source is not cropped twice")
        let aspectOutput = try render(chain, device: device, queue: queue, source: source,
                                      width: 6, height: 4, aspect: CGSize(width: 1, height: 2))
        let middle = scaled(colors, scaleX: 1, scaleY: 2)
        let bars: [UInt8] = [0, 0, 0, 255, 0, 0, 0, 255]
        var expectedAspect = [UInt8]()
        for row in 0..<4 {
            expectedAspect.append(contentsOf: bars)
            expectedAspect.append(contentsOf: middle[(row * 8)..<(row * 8 + 8)])
            expectedAspect.append(contentsOf: bars)
        }
        try require(chain.outputBounds == CGRect(x: 2, y: 0, width: 2, height: 4),
                    "No Shader must preserve aspect-correct centered output bounds")
        try requirePixels(aspectOutput, expectedAspect, "aspect ratio and clear letterbox bars are preserved")

        let effect = try makeEffect(in: workspace)
        let effectModel = try SlangShader(fromURL: effect)
        let compiledEffect = try ShaderPassCompiler(shaderModel: effectModel).compile(options: options)
        try require(compiledEffect.passes.count == 1, "Test inversion effect must really compile one pass")
        let inverted = colors.enumerated().map { $0.offset % 4 == 3 ? $0.element : 255 - $0.element }
        for cycle in 1...2 {
            try chain.setShader(fromURL: effect, options: options)
            try requirePixels(render(chain, device: device, queue: queue, source: source), inverted,
                              "cycle \(cycle): selected effect really changes pixels")
            try chain.setShader(fromURL: preset, options: options)
            try requirePixels(render(chain, device: device, queue: queue, source: source), colors,
                              "cycle \(cycle): No Shader removes previous effect immediately")
        }

        let midtones: [UInt8] = [16, 64, 144, 255, 96, 160, 224, 255,
                                 32, 112, 192, 255, 208, 80, 48, 255]
        // Use a fresh source per frame, as a running core provides a new frame.
        // This also prevents an existing adjustment prepass from changing the
        // next test's source through its same-size history texture reuse.
        for (gamma, saturation, name) in [(2.0, 1.0, "gamma"), (1.0, 0.0, "saturation"), (1.8, 0.4, "combined color controls")] {
            chain.setShaderParameters(gamma: Float(gamma), saturation: Float(saturation))
            try chain.setShader(fromURL: preset, options: options)
            let adjustedFrame = try render(chain, device: device, queue: queue,
                                           source: sourceTexture(device, bytes: midtones),
                                           sourceOrigin: CGPoint(x: 3, y: 5))
            let expected = adjusted(midtones, gamma: gamma, saturation: saturation)
            try requirePixels(adjustedFrame, expected, "independent \(name) remain active with No Shader", tolerance: 2)
            try chain.setShader(fromURL: effect, options: options)
            _ = try render(chain, device: device, queue: queue, source: sourceTexture(device, bytes: midtones))
            try chain.setShader(fromURL: preset, options: options)
            try requirePixels(render(chain, device: device, queue: queue,
                                     source: sourceTexture(device, bytes: midtones)), expected,
                              "independent \(name) survive effect → No Shader", tolerance: 2)
        }
        chain.setShaderParameters(gamma: 1, saturation: 1)
        try requirePixels(render(chain, device: device, queue: queue,
                                 source: sourceTexture(device, bytes: midtones)), midtones,
                          "neutral color controls restore exact original midtone pixels")
        print("PASS: No Shader offscreen rendering regression suite; no app or emulator core was launched")
    }
}
