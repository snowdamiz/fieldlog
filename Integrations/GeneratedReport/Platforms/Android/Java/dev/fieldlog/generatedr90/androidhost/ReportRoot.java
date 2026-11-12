package dev.fieldlog.generatedr90.androidhost;

import java.io.File;
import java.io.IOException;

/** Canonicalize the trusted Context root before crossing the Swift boundary. */
final class ReportRoot {
    private ReportRoot() {}
    static File canonical(File files) throws IOException {
        return files.getCanonicalFile();
    }
}
