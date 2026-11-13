package dev.fieldlog.generatedr90.androidhost;

import java.io.*;
import java.nio.file.*;
import java.util.*;

public final class ReportFilesChecks {
    interface Checked { void run() throws Exception; }
    static int passed;
    static void check(String label, Checked body) throws Exception {
        body.run(); passed++; System.out.println("PASS " + label);
    }
    static void require(boolean value) { if (!value) throw new AssertionError(); }
    static void refused(Checked body) throws Exception {
        try { body.run(); } catch (IOException | IllegalArgumentException expected) { return; }
        throw new AssertionError("accepted invalid report input");
    }
    public static void main(String[] args) throws Exception {
        Path root = Files.createDirectories(Path.of(args[0])).toRealPath();
        Path files = Files.createDirectory(root.resolve("files"));
        Path exports = Files.createDirectories(files.resolve("FieldLog/exports"));
        Path alias = Files.createSymbolicLink(root.resolve("alias"), files);
        String name = "FieldLog-00000000-0000-0000-0000-000000000001-r1.txt";
        byte[] bytes = "Actual saved report 👩🏽‍🔬\nNo upload\n".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        Path report = Files.write(exports.resolve(name), bytes);
        File cache = root.resolve("cache").toFile();
        check("trusted root alias canonicalized before Swift", () -> require(PublicBridge.ReportRoot.canonical(alias.toFile()).equals(files.toFile())));
        check("canonical root stable", () -> require(PublicBridge.ReportRoot.canonical(files.toFile()).equals(files.toFile())));
        check("canonical report accepted through trusted alias", () -> require(PublicBridge.ReportFiles.source(alias.toFile(), report.toString(), bytes.length).equals(report.toFile())));
        check("noncanonical report path refused", () -> refused(() -> PublicBridge.ReportFiles.source(alias.toFile(), alias.resolve("FieldLog/exports").resolve(name).toString(), bytes.length)));
        check("wrong size refused", () -> refused(() -> PublicBridge.ReportFiles.source(files.toFile(), report.toString(), bytes.length+1)));
        check("zero size refused", () -> refused(() -> PublicBridge.ReportFiles.source(files.toFile(), report.toString(), 0)));
        check("oversize refused", () -> refused(() -> PublicBridge.ReportFiles.source(files.toFile(), report.toString(), (long)PublicBridge.ReportFiles.MAX_BYTES+1)));
        Path outside=Files.write(root.resolve(name), bytes);
        check("outside export directory refused", () -> refused(() -> PublicBridge.ReportFiles.source(files.toFile(), outside.toString(), bytes.length)));
        Path child=Files.createSymbolicLink(exports.resolve("FieldLog-00000000-0000-0000-0000-000000000002-r1.txt"), outside);
        check("child symlink refused", () -> refused(() -> PublicBridge.ReportFiles.source(files.toFile(), child.toString(), bytes.length)));
        Files.delete(child);
        Path original=exports.resolveSibling("original"); Files.move(exports,original); Files.createSymbolicLink(exports,original);
        check("export directory symlink refused", () -> refused(() -> PublicBridge.ReportFiles.source(files.toFile(), report.toString(), bytes.length)));
        Files.delete(exports); Files.move(original,exports);
        check("truncated stream refused and scratch removed", () -> {
            refused(() -> PublicBridge.ReportFiles.copy(cache,new ByteArrayInputStream(new byte[0]),bytes.length));
            try(var entries=Files.list(cache.toPath())) { require(entries.count()==0); }
        });
        check("overlong stream refused and scratch removed", () -> {
            refused(() -> PublicBridge.ReportFiles.copy(cache,new ByteArrayInputStream(new byte[bytes.length+1]),bytes.length));
            try(var entries=Files.list(cache.toPath())) { require(entries.count()==0); }
        });
        File copied=PublicBridge.ReportFiles.copy(cache,new ByteArrayInputStream(bytes),bytes.length);
        check("copied report bytes exact", () -> require(Arrays.equals(Files.readAllBytes(copied.toPath()),bytes)));
        String token="00000000-0000-0000-0000-000000000003";
        PublicBridge.ReportFiles.publish(token,copied,bytes.length,100);
        check("wrong token refused", () -> refused(() -> PublicBridge.ReportFiles.lookup("00000000-0000-0000-0000-000000000004",101)));
        var readers=new ArrayList<PublicBridge.ReportFiles.Entry>();
        for(int n=0;n<PublicBridge.ReportFiles.MAX_READERS;n++)readers.add(PublicBridge.ReportFiles.acquire(token,101));
        check("reader limit refused", () -> refused(() -> PublicBridge.ReportFiles.acquire(token,101)));
        PublicBridge.ReportFiles.revoke(token);
        check("revocation retains active reader file", () -> require(copied.isFile()));
        for(var reader:readers)PublicBridge.ReportFiles.release(reader);
        check("last reader removes retired copy", () -> require(!copied.exists()));
        File next=PublicBridge.ReportFiles.copy(cache,new ByteArrayInputStream(bytes),bytes.length);
        PublicBridge.ReportFiles.publish(token,next,bytes.length,100);
        check("expiry revokes and removes copy", () -> {
            refused(() -> PublicBridge.ReportFiles.lookup(token,100+PublicBridge.ReportFiles.LIFETIME_MS));
            require(!next.exists());
        });
        Path cacheAlias=Files.createSymbolicLink(root.resolve("cache-alias"),cache.toPath());
        check("cache alias refused", () -> refused(() -> PublicBridge.ReportFiles.initialize(cacheAlias.toFile())));
        check("source report preserved", () -> require(Arrays.equals(Files.readAllBytes(report),bytes)));
        System.out.println("RESULT passed="+passed+" failed=0");
    }
}
