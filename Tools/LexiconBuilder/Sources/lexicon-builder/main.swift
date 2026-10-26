import Foundation
import LexiconBuilderCore

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(2) }

var args = Array(CommandLine.arguments.dropFirst())
var sources: String?, out: String?
var options = LMOptions()
while !args.isEmpty {
    let a = args.removeFirst()
    func val() -> String { if args.isEmpty { fail("missing value for \(a)") }; return args.removeFirst() }
    switch a {
    case "--sources": sources = val()
    case "--out": out = val()
    case "--min-ngram-count": guard let v = UInt64(val()) else { fail("bad --min-ngram-count") }; options.minCount = v
    case "--max-bigrams": guard let v = Int(val()) else { fail("bad --max-bigrams") }; options.maxBigrams = v
    case "--max-trigrams": guard let v = Int(val()) else { fail("bad --max-trigrams") }; options.maxTrigrams = v
    case "-h", "--help":
        print("usage: lexicon-builder --sources sources.json --out DIR [--min-ngram-count N] [--max-bigrams N] [--max-trigrams N]")
        exit(0)
    default: fail("unknown argument \(a)")
    }
}
guard let sources, let out else { fail("--sources and --out are required") }
do {
    let r = try run(manifestURL: URL(fileURLWithPath: sources), outDir: URL(fileURLWithPath: out, isDirectory: true), options: options)
    print(r.report.text, terminator: "")
} catch {
    fail("error: \(error)")
}
