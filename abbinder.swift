//
//  Copyright (c) 2009-2026 Oleksandr Tymoshenko <gonzo@bluezbox.com>
//  All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions
//  are met:
//  1. Redistributions of source code must retain the above copyright
//     notice unmodified, this list of conditions, and the following
//     disclaimer.
//  2. Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer in the
//     documentation and/or other materials provided with the distribution.
//
//  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
//  ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
//  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
//  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
//  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
//  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
//  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
//  SUCH DAMAGE.
//

import ArgumentParser
import Foundation

@main
struct abbinder: ParsableCommand {
    static let validRates: [Int32] = [
        8000, 11025, 12000, 16000, 22050,
        24000, 32000, 44100, 48000
    ]

    @Option(name: .customShort("a"),
            help: ArgumentHelp("book author", valueName: "author"))
    var bookAuthor: String = ""
    @Option(name: .short,
            help: ArgumentHelp("set bitrate (kbps)", valueName: "bitrate"))
    var bitrate: Int32?
    @Option(name: .short,
            help: ArgumentHelp("number of channels in audiobook", valueName: "channels"))
    var channels: UInt32 = 2
    @Option(name: .customShort("C"),
            help: ArgumentHelp("cover image", valueName: "image"))
    var coverFile: String?
    @Flag(name: .customShort("e"),
          help: ArgumentHelp("shortcut for -E \"\""))
    var fileChaptersEmptyTemplate = false
    @Option(name: .customShort("E"),
            help: ArgumentHelp("make each file a chapter with name defined by template\n%N - chapter number\n%a - artis (obtained from source file)\n%t - title (obtained from source file)", valueName: "template"))
    var fileChapterTemplate: String?
    @Option(name: .customShort("g"),
            help: ArgumentHelp("book genre", valueName: "genre"))
    var bookGenre: String = ""
    @Option(name: .customShort("i"),
            help: ArgumentHelp("get input files list from file, \"-\" for standard input", valueName: "file"))
    var inputFilenamesListFile: String?
    @Option(name: .customShort("l"),
            help: ArgumentHelp("split audiobook to volumes max # hours long", valueName: "hours"))
    var maxVolumeDuration: UInt64?
    @Option(name: .short,
            help: ArgumentHelp("audiobook output file", valueName: "outfile"))
    var outFile: String
    @Flag(name: .short,
          help: ArgumentHelp("quiet mode (no output)"))
    var quiet = false
    @Option(name: .customShort("r"),
            help: ArgumentHelp("sample rate of audiobook", valueName: "samplerate"))
    var samplerate: Int32 = 44100
    @Flag(name: .short,
          help: ArgumentHelp("skip errors and go on with conversion"))
    var skipErrors = false
    @Option(name: .customShort("t"),
            help: ArgumentHelp("book title", valueName: "title"))
    var bookTitle: String = ""
    @Flag(name: .short,
          help: ArgumentHelp("print some info on files being converted"))
    var verbose = false


    @Argument(help: ArgumentHelp("input files and chapter names"))
    var argFilenames: [String] = []

    // Write a message to standard error (equivalent of fprintf(stderr, ...))
    func errPrint(_ s: String) {
        guard let data = "\(s)".data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }

    mutating func validate() throws {
        if !abbinder.validRates.contains(samplerate) {
            throw ValidationError("invalid samplerate(-r) \(samplerate). Valid values: \(abbinder.validRates)")
        }
        if (channels != 1) && (channels != 2) {
            throw ValidationError("invalid number of channels(-c) \(channels). Valid values: [1, 2]")
        }
        if let bitrate, bitrate <= 0 || bitrate > Int32(UInt32.max / 1000) {
            throw ValidationError("bitrate must be a positive number of kbps")
        }
        if let hours = maxVolumeDuration, hours == 0 || hours > UInt64.max / 3_600_000 {
            throw ValidationError("volume duration must be a positive number of hours")
        }
        if fileChaptersEmptyTemplate && fileChapterTemplate != nil {
            throw ValidationError("can not combine -e and -E options")
        }
    }

    func usage(_ cmd: String) {
        print(
            "Usage: \(cmd) [-Aehqsv] [-c 1|2] [-r samplerate] [-a author] [-t title] [-i filelist] -o outfile [@chapter_1@ infile @chapter_2@ ...]"
        )
        print("\t-b bitrate\tset bitrate (kbps)")
        print("\t-c 1|2\t\tnumber of channels in audiobook. Default: 2")
        print("\t-C file.png\tcover image")
        print("\t-e\t\talias for -E ''")
        print(
            "\t-E template\tmake each file a chapter with name defined by template"
        )
        print("\t\t\t    %N - chapter number")
        print("\t\t\t    %a - artis (obtained from source file)")
        print("\t\t\t    %t - title (obtained from source file)")
        print(
            "\t-i file\t\tget input files list from file, \"-\" for standard input"
        )
        print("\t-l hours\t\tsplit audiobook to volumes max # hours long")
        print("\t-o outfile\t\taudiobook output file")
        print("\t-r rate\t\tsample rate of audiobook. Default: 44100")
        print("\t-s\t\tskip errors and go on with conversion")
    }

    func makeChapterName(_ format: String, _ chapterNum: Int, _ file: AudioFile) -> String {
        format
            .replacingOccurrences(of: "%a", with: file.artist)
            .replacingOccurrences(of: "%t", with: file.name)
            .replacingOccurrences(of: "%N", with: "\(chapterNum + 1)")
    }

    nonisolated func run() throws {
        let binder = AudioBinder()!
        var withChapters = false
        var eachFileIsChapter = false

        var chapterNameFormat: String?
        var currentChapters = [Chapter]()
        var volumeChapters = [[Chapter]]()

        var inputFiles = [AudioFile]()
        var inputFilenames = argFilenames

        if let listFile = inputFilenamesListFile {
            do {
                let content: String
                if listFile == "-" {
                    let stdinData = FileHandle.standardInput.readDataToEndOfFile()
                    guard let text = String(data: stdinData, encoding: .utf8) else {
                        throw ValidationError("input list must be UTF-8")
                    }
                    content = text
                } else {
                    content = try String(contentsOfFile: listFile, encoding: .utf8)
                }
                inputFilenames = content.components(separatedBy: .newlines)
            } catch {
                print("Failed to read list of input files: \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }

        if inputFilenames.allSatisfy({ $0.isEmpty }) {
            errPrint("No input file specified")
            throw ExitCode.failure
        }

        chapterNameFormat = fileChaptersEmptyTemplate ? "" : fileChapterTemplate

        if chapterNameFormat != nil {
            withChapters = true
            eachFileIsChapter = true
        }

        // check if we have chapter markers in file list
        for path in inputFilenames {
            if path.isEmpty {
                continue
            }

            // is it chapter marker?
            if path.count >= 2 && path.hasPrefix("@") && path.hasSuffix("@") {
                if withChapters {
                    errPrint(
                        "You can not use -e/-E and chapter marks together"
                    )
                    throw ExitCode.failure
                }
                withChapters = true
                break
            }
        }

        // split output filename to base and extension in order to get
        // filenames for consecutive volume files
        let outFileBase = URL(fileURLWithPath: outFile).deletingPathExtension().path
        let outFileExt = URL(fileURLWithPath: outFile).pathExtension

        // create implicit first chapter. It wil be overriden
        // if files list starts with chapter marker
        var estTotalDuration: UInt64 = 0
        var currentVolumeName = outFile
        var totalVolumes = 0
        let maxDurationSeconds = maxVolumeDuration.map { $0 * 3600 }
        var curChapter = Chapter()
        for path in inputFilenames {
            if path.isEmpty {
                continue
            }

            // is it chapter marker?
            if path.count >= 2 && path.hasPrefix("@") && path.hasSuffix("@") {
                let chapterName = String(path.dropFirst().dropLast())
                curChapter = Chapter()
                if verbose {
                    print("Chapter marker detected: '\(chapterName)'")
                }
                curChapter.name = chapterName
                currentChapters.append(curChapter)
                continue
            }

            guard let file = AudioFile(path: path) else {
                throw ExitCode.failure
            }
            // TODO: this should be handled by AudioFile constructor
            if !file.valid {
                errPrint( "\(path) is not a valid audio file\n")
                if skipErrors {
                    continue
                }
                throw ExitCode.failure
            }
            if let maxDuration = maxDurationSeconds, UInt64(file.duration.intValue) > maxDuration * 1000 {
                errPrint("\(path) is longer than the maximum volume duration\n")
                throw ExitCode.failure
            }
            if let maxDuration = maxDurationSeconds,
               (estTotalDuration + UInt64(file.duration.intValue)) > maxDuration * 1000 {
                if !inputFiles.isEmpty {
                    binder.addVolume(currentVolumeName, files: inputFiles)
                    inputFiles.removeAll()
                    estTotalDuration = 0
                    totalVolumes += 1
                    currentVolumeName = "\(outFileBase)-\(totalVolumes).\(outFileExt)"
                    // restart chapter
                    volumeChapters.append(currentChapters.filter { $0.totalFiles() > 0 })
                    currentChapters = []
                    let c = Chapter()
                    c.name = curChapter.name
                    curChapter = c
                } else {
                    errPrint(
                        "\(path): duration (\(file.duration.intValue / 1000) sec) is larger than the maximum volume duration (\(maxDuration) sec.)\n"
                    )
                    throw ExitCode.failure
                }
            }

            inputFiles.append(file)
            estTotalDuration += UInt64(file.duration.intValue)

            if withChapters {
                if eachFileIsChapter {
                    let chapter = Chapter()
                    chapter.name = makeChapterName(
                        chapterNameFormat!,
                        currentChapters.count,
                        file
                    )
                    chapter.addFile(file)
                    currentChapters.append(chapter)
                } else {
                    // at this point we should have at least one item in chapters
                    // list. If there is none - the first element of files list is
                    // not chapter mark and we should add our implicit marker
                    if currentChapters.isEmpty {
                        currentChapters.append(curChapter)
                    }

                    curChapter.addFile(file)
                }
            }
        }

        // Add last volume to the binder
        binder.addVolume(currentVolumeName, files: inputFiles)
        // add chapters for last volume
        volumeChapters.append(currentChapters.filter { $0.totalFiles() > 0 })

        binder.channels = channels
        binder.sampleRate = Float(samplerate)

        if let bitrate {
            let bitrateBps = UInt32(bitrate) * 1000
            guard let validBitrates = binder.validBitrates() else { throw ExitCode.failure }
            var found = false
            for rate in validBitrates {
                if let rate = rate as? NSNumber, rate.uint32Value == bitrateBps {
                    binder.bitrate = bitrateBps
                    found = true
                    break
                }
            }

            if !found {
                errPrint("Invalid bitrate value \(bitrate), valid values:\n    ")
                var first = true
                for rate in validBitrates {
                    if !first { errPrint(", ") }
                    errPrint("\((rate as! NSNumber).uint32Value / 1000)")
                    first = false
                }
                errPrint("\n")
                throw ExitCode.failure
            }
        }

        // Setup delegate, it will print progress messages on console
        let delegate = ConsoleDelegate()
        delegate.quiet = quiet
        delegate.verbose = verbose
        delegate.skipErrors = skipErrors
        binder.setDelegate(delegate)
        defer { withExtendedLifetime(delegate) {} }

        if !binder.convert() {
            print("Conversion failed")
            throw ExitCode.failure
        }

        let volumes = binder.volumes!
        let totalTracks = volumes.count
        if !quiet {
            print("Adding metadata, it may take a while...", terminator: "")
            fflush(stdout)
        }

        for (track, v) in zip(1..., volumes.compactMap({ $0 as? AudioBookVolume })) {
            let mp4 = MP4File(fileName: v.filename)!
            mp4.artist = bookAuthor
            mp4.title = totalTracks > 1 ? "\(bookTitle) #\(String(format: "%02ld", track))" : bookTitle
            mp4.album = bookTitle
            mp4.coverFile = coverFile
            mp4.tracksTotal = UInt16(totalTracks)
            mp4.track = UInt16(track)
            if !bookGenre.isEmpty {
                mp4.genre = bookGenre
            }
            mp4.gaplessPlay = totalTracks > 1
            guard mp4.update() else {
                errPrint("Failed to write metadata to \(v.filename!)\n")
                throw ExitCode.failure
            }
        }

        if !quiet {
            print("done")
        }

        if withChapters {
            if !quiet {
                print(
                    "Adding chapter markers, it may take a while...",
                    terminator: ""
                )
                fflush(stdout)
            }
            for (v, chapters) in zip(volumes.compactMap({ $0 as? AudioBookVolume }), volumeChapters) {
                guard addChapters(v.filename, chapters) == 0 else {
                    errPrint("Failed to write chapters to \(v.filename!)\n")
                    throw ExitCode.failure
                }
            }
            if !quiet {
                print("done")
            }
        }

        if !quiet {
            print("done")
        }
    }
}
