package dev.fieldlog.generatedr90.androidhost;
import android.content.*;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.*;
import android.provider.OpenableColumns;
import java.io.*;
import java.nio.file.*;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.UUID;
public final class PublicBridge {
    static { System.loadLibrary("mixer_public_android_jni"); }
    private PublicBridge() {}
    public static long open(PublicActivity receiver, String profile) {
        requireMain();
        try {
            File files=receiver.getFilesDir(), canonical=ReportRoot.canonical(files);
            android.util.Log.i("FieldLogShareR1702", "open rootCanonical="+files.getAbsoluteFile().equals(canonical));
            return openNative(receiver, profile, canonical.getPath().getBytes(java.nio.charset.StandardCharsets.UTF_8));
        } catch (IOException error) {
            android.util.Log.e("FieldLogShareR1702", "open-root exceptionClass="+error.getClass().getSimpleName());
            return 0;
        }
    }
    public static int event(long context, byte[] owner, byte[] envelope) { requireMain(); return eventNative(context, owner, envelope); }
    public static int close(long context) { requireMain(); return closeNative(context); }
    public static int photo(long context, byte[] request, int result, byte[] jpeg) { requireMain(); return photoNative(context, request, result, jpeg); }
    public static int report(long context, byte[] request, int result) { requireMain(); android.util.Log.i("FieldLogShareR1702", "report-jni-enter"); int status=reportNative(context, request, result); android.util.Log.i("FieldLogShareR1702", "report-jni-return accepted="+(status==0)); return status; }
    private static native int reportNative(long context, byte[] request, int result);
    private static native int photoNative(long context, byte[] request, int result, byte[] jpeg);
    private static native long openNative(PublicActivity receiver, String profile, byte[] directory);
    private static native int eventNative(long context, byte[] originalOwner, byte[] originalEnvelope);
    private static native int closeNative(long context);
    private static void requireMain() {
        if (android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) throw new IllegalStateException("Android main thread required");
    }
public static final class ReportProvider extends ContentProvider {
    static final String AUTHORITY="dev.fieldlog.generatedr90.reports";
    private static final Handler CLOSES=new Handler(Looper.getMainLooper());
    static Uri uri(String token) { return new Uri.Builder().scheme("content").authority(AUTHORITY).appendPath(ReportFiles.token(token)).build(); }
    static String token(Uri uri) throws FileNotFoundException {
        if (uri==null || !"content".equals(uri.getScheme()) || !AUTHORITY.equals(uri.getAuthority()) ||
            uri.getQuery()!=null || uri.getFragment()!=null || uri.getPathSegments().size()!=1)
            throw new FileNotFoundException("report URI");
        String token=uri.getPathSegments().get(0);
        try { ReportFiles.token(token); } catch (IllegalArgumentException e) { throw new FileNotFoundException("report URI"); }
        if (!uri.equals(uri(token))) throw new FileNotFoundException("noncanonical report URI");
        return token;
    }
    @Override public boolean onCreate() {
        try { ReportFiles.initialize(new File(getContext().getCacheDir(),"fieldlog-report-share")); return true; }
        catch (IOException | RuntimeException error) { return false; }
    }
    @Override public String getType(Uri uri) {
        try { ReportFiles.lookup(token(uri),SystemClock.elapsedRealtime()); return "text/plain"; }
        catch (IOException e) { throw new IllegalArgumentException("report unavailable",e); }
    }
    @Override public ParcelFileDescriptor openFile(Uri uri,String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException("report is read only");
        ReportFiles.Entry entry=ReportFiles.acquire(token(uri),SystemClock.elapsedRealtime());
        try {
            return ParcelFileDescriptor.open(entry.file,ParcelFileDescriptor.MODE_READ_ONLY,CLOSES,error -> ReportFiles.release(entry));
        } catch (IOException | RuntimeException | OutOfMemoryError error) {
            ReportFiles.release(entry); throw new FileNotFoundException("report open failed");
        }
    }
    @Override public Cursor query(Uri uri,String[] projection,String selection,String[] selectionArgs,String sortOrder) {
        if (selection!=null || selectionArgs!=null || sortOrder!=null) throw new IllegalArgumentException("report query");
        try {
            ReportFiles.Entry entry=ReportFiles.lookup(token(uri),SystemClock.elapsedRealtime());
            String[] columns=projection==null ? new String[]{OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE}:projection;
            if (columns.length>2) throw new IllegalArgumentException("report columns");
            Object[] values=new Object[columns.length];
            for(int i=0;i<columns.length;i++) {
                if(OpenableColumns.DISPLAY_NAME.equals(columns[i])) values[i]="FieldLog-report.txt";
                else if(OpenableColumns.SIZE.equals(columns[i])) values[i]=entry.size;
                else throw new IllegalArgumentException("report column");
            }
            MatrixCursor cursor=new MatrixCursor(columns,1); cursor.addRow(values); return cursor;
        } catch(IOException e) { throw new IllegalArgumentException("report unavailable",e); }
    }
    @Override public Uri insert(Uri uri,ContentValues values) { throw new UnsupportedOperationException("read only"); }
    @Override public int update(Uri uri,ContentValues values,String selection,String[] args) { throw new UnsupportedOperationException("read only"); }
    @Override public int delete(Uri uri,String selection,String[] args) { throw new UnsupportedOperationException("read only"); }
}

static final class ReportFiles {
    static final int MAX_BYTES = 36 * 1024 * 1024, MAX_READERS = 4;
    static final long LIFETIME_MS = 600000;
    static final class Entry {
        final String token; final File file; final long size, expires;
        int readers; boolean retired;
        Entry(String token, File file, long size, long now) {
            this.token=token; this.file=file; this.size=size; expires=now+LIFETIME_MS;
        }
    }
    static final class WorkLease {
        private boolean cancelled, done, copying;
        private Thread worker;
        private File prepared;
        private WorkLease() {}
    }
    private static WorkLease work;
    static synchronized WorkLease reserveWork() {
        if (!cleanupRetired()) return null;
        if (work!=null && work.cancelled && !work.copying) cleanupPrepared(work);
        if (work!=null && work.done && work.prepared==null &&
            (work.worker==null || !work.worker.isAlive())) work=null;
        if (work!=null) return null;
        WorkLease lease=new WorkLease(); work=lease; return lease;
    }
    static synchronized void bindWorker(WorkLease lease,Thread worker) {
        if (work!=lease || lease.worker!=null) throw new IllegalStateException("report worker ownership");
        lease.worker=worker;
    }
    static synchronized boolean prepareWork(WorkLease lease,File file) {
        return work==lease && !lease.cancelled && !lease.copying && lease.prepared==file;
    }
    static synchronized boolean takePrepared(WorkLease lease,File file) {
        if (work!=lease || lease.cancelled || lease.prepared!=file) return false;
        return true;
    }
    static synchronized void cancelWork(WorkLease lease) {
        if (lease==null || work!=lease) return;
        lease.cancelled=true;
        if (!lease.copying) cleanupPrepared(lease);
    }
    static synchronized void workerFinished(WorkLease lease) {
        if (work==lease) lease.done=true;
    }
    static synchronized void failedBeforeStart(WorkLease lease) {
        if (work==lease && (lease.worker==null || lease.worker.getState()==Thread.State.NEW)) {
            cancelWork(lease); lease.done=true;
            if (lease.prepared==null) work=null;
        }
    }
    private static Entry active;
    private static int readers;
    private static final Entry[] retired=new Entry[MAX_READERS+2];
    private static boolean unlink(File file) {
        try {
            File parent=file.getParentFile();
            if (parent==null || !parent.equals(parent.getCanonicalFile()) || !file.equals(file.getCanonicalFile())) return false;
            BasicFileAttributes a=Files.readAttributes(file.toPath(),BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);
            if (!a.isRegularFile() || a.isSymbolicLink()) return false;
            if (!file.delete()) return false;
            try { Files.readAttributes(file.toPath(),BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS); return false; }
            catch (NoSuchFileException absent) { return true; }
        } catch (NoSuchFileException absent) { return true; }
        catch (IOException | RuntimeException unavailable) { return false; }
    }
    private static void cleanupPrepared(WorkLease lease) {
        if (lease.prepared!=null && unlink(lease.prepared)) lease.prepared=null;
    }
    private static boolean cleanupRetired() {
        boolean clean=true;
        for(int i=0;i<retired.length;i++) {
            Entry entry=retired[i];
            if (entry!=null && entry.readers==0) {
                if (unlink(entry.file)) retired[i]=null; else clean=false;
            }
        }
        return clean;
    }
    static String token(String value) {
        if (value == null || value.length()!=36 || !UUID.fromString(value).toString().equals(value))
            throw new IllegalArgumentException("invalid report token");
        return value;
    }
    static File source(File files, String path, long size) throws IOException {
        if (path == null || path.getBytes(java.nio.charset.StandardCharsets.UTF_8).length>4096 || size<=0 || size>MAX_BYTES)
            throw new IOException("report bound");
        File trusted=files.getCanonicalFile(), fieldlog=new File(trusted,"FieldLog"), root=new File(fieldlog,"exports"), candidate=new File(path);
        if (!fieldlog.equals(fieldlog.getCanonicalFile()) || !root.equals(root.getCanonicalFile()) ||
            !Files.isDirectory(fieldlog.toPath(),LinkOption.NOFOLLOW_LINKS) || !Files.isDirectory(root.toPath(),LinkOption.NOFOLLOW_LINKS))
            throw new IOException("report export directory");
        if (!candidate.isAbsolute() || !candidate.getAbsoluteFile().equals(candidate.getCanonicalFile()) ||
            !root.equals(candidate.getParentFile()) ||
            !candidate.getName().matches("FieldLog-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-r[0-9]{1,20}\\.txt"))
            throw new IOException("report path");
        BasicFileAttributes a=Files.readAttributes(candidate.toPath(),BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);
        if (!a.isRegularFile() || a.isSymbolicLink() || a.size()!=size) throw new IOException("report source");
        return candidate;
    }
    private static File initializedDirectory;
    // At most four retired reader-backed copies, one current mapping and one worker.
    static final int MAX_COPIES = MAX_READERS + 2;
    static synchronized void initialize(File directory) throws IOException {
        File canonical=directory.getCanonicalFile();
        if (Files.isSymbolicLink(directory.toPath())) throw new IOException("report cache path");
        if (initializedDirectory!=null) {
            if (!initializedDirectory.equals(canonical)) throw new IOException("report cache changed");
            return;
        }
        if (!Files.exists(directory.toPath(),LinkOption.NOFOLLOW_LINKS)) Files.createDirectory(directory.toPath());
        BasicFileAttributes root=Files.readAttributes(directory.toPath(),BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);
        if (!root.isDirectory() || root.isSymbolicLink()) throw new IOException("report cache directory");
        java.util.ArrayList<Path> paths=new java.util.ArrayList<>();
        java.util.ArrayList<BasicFileAttributes> identities=new java.util.ArrayList<>();
        long total=0;
        try (DirectoryStream<Path> entries=Files.newDirectoryStream(directory.toPath())) {
            for (Path entry:entries) {
                if (paths.size()>=MAX_COPIES || !entry.getFileName().toString().matches("report-[0-9]{1,20}\\.txt"))
                    throw new IOException("unexpected report cache entry");
                BasicFileAttributes a=Files.readAttributes(entry,BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);
                if (!a.isRegularFile() || a.isSymbolicLink() || a.size()>MAX_BYTES ||
                    (total+=a.size())>(long)MAX_COPIES*MAX_BYTES) throw new IOException("report cache bound");
                paths.add(entry); identities.add(a);
            }
        }
        // Refuse the entire inventory before deleting any unexpected entry.
        for(int i=0;i<paths.size();i++) {
            BasicFileAttributes a=Files.readAttributes(paths.get(i),BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);
            BasicFileAttributes before=identities.get(i);
            if (!a.isRegularFile() || a.isSymbolicLink() || a.size()!=before.size() ||
                !java.util.Objects.equals(a.fileKey(),before.fileKey())) throw new IOException("report cache changed");
        }
        for(Path path:paths) if (!unlink(path.toFile())) throw new IOException("report cache cleanup");
        initializedDirectory=canonical;
    }
    static File copy(File directory, InputStream input, long size) throws IOException {
        if (size<=0 || size>MAX_BYTES) throw new IOException("report bound");
        final WorkLease lease;
        final File temp;
        synchronized (ReportFiles.class) {
            if (!cleanupRetired()) throw new IOException("report cleanup pending");
            if (work!=null && work.worker==Thread.currentThread()) lease=work;
            else {
                lease=reserveWork();
                if (lease==null) throw new IOException("report worker ownership");
                lease.done=true;
            }
            if (lease.cancelled || lease.prepared!=null) throw new IOException("report cancelled");
            initialize(directory);
            temp=File.createTempFile("report-",".txt",directory);
            lease.prepared=temp; lease.copying=true;
        }
        boolean complete=false;
        try {
            try (OutputStream output=new FileOutputStream(temp)) {
                byte[] buffer=new byte[16384]; long total=0; int count;
                while ((count=input.read(buffer,0,(int)Math.min(buffer.length,size-total+1)))!=-1) {
                    if (Thread.currentThread().isInterrupted() || count<=0 || count>size-total) throw new IOException("report changed or cancelled");
                    output.write(buffer,0,count); total+=count;
                }
                if (total!=size) throw new IOException("report truncated");
            }
            if (!temp.setReadOnly()) throw new IOException("report permissions");
            complete=true; return temp;
        } finally {
            synchronized (ReportFiles.class) {
                lease.copying=false;
                if (!complete || lease.cancelled) cancelWork(lease);
            }
        }
    }
    static synchronized Entry publish(String value,File file,long size,long now) throws IOException {
        token(value);
        if (active!=null || size<=0 || size>MAX_BYTES || file.length()!=size) throw new IOException("report already active or invalid");
        if (work==null || work.cancelled || work.copying || work.prepared!=file) throw new IOException("report file ownership");
        active=new Entry(value,file,size,now);
        work.prepared=null; return active;
    }
    static synchronized Entry lookup(String value,long now) throws FileNotFoundException {
        try { token(value); } catch (IllegalArgumentException e) { throw new FileNotFoundException("report token"); }
        if (active!=null && now>=active.expires) revoke(active.token);
        if (active==null || !active.token.equals(value)) throw new FileNotFoundException("report unavailable");
        return active;
    }
    static synchronized Entry acquire(String value,long now) throws FileNotFoundException {
        Entry entry=lookup(value,now);
        if (readers>=MAX_READERS) throw new FileNotFoundException("report reader limit");
        readers++; entry.readers++; return entry;
    }
    static synchronized void release(Entry entry) {
        if (entry.readers<=0) throw new IllegalStateException("report lease already closed");
        entry.readers--; readers--; if (entry.retired && entry.readers==0) cleanupRetired();
    }
    static synchronized void revoke(String value) {
        if (active==null || !active.token.equals(value)) return;
        Entry entry=active;
        int slot=0; while(slot<retired.length && retired[slot]!=null) slot++;
        if (slot==retired.length) throw new IllegalStateException("report retired bound");
        retired[slot]=entry; entry.retired=true; active=null;
        cleanupRetired();
    }
}

static final class ReportIntent {
    static Intent chooser(Uri uri) {
        Intent send=new Intent(Intent.ACTION_SEND).setType("text/plain")
            .putExtra(Intent.EXTRA_STREAM,uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        send.setClipData(ClipData.newRawUri("FieldLog report",uri));
        Intent chooser=Intent.createChooser(send,"Share project report").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        chooser.setClipData(send.getClipData()); return chooser;
    }
}

}
