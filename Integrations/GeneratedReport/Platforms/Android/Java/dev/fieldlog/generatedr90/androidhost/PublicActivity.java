package dev.fieldlog.generatedr90.androidhost;
import android.app.Activity;
import android.content.Intent;
import android.content.res.AssetFileDescriptor;
import android.graphics.Bitmap;
import android.graphics.ImageDecoder;
import android.net.Uri;
import android.os.CancellationSignal;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.WindowInsetsController;
import android.widget.FrameLayout;
import dev.mixer.android.AndroidUIProfile;
import dev.mixer.android.AndroidUINativeSurface;
import java.util.Arrays;
import java.util.ArrayDeque;

public final class PublicActivity extends Activity {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private FrameLayout root;
    private AndroidUINativeSurface surface;
    private byte[] owner;
    private long context;
    private boolean destroyed, failed, drainScheduled, draining;
    private static final int MAX_EVENTS = 32, MAX_BYTES = 1048576;
    private byte[] pendingReport;
    private long reportContext;
    private boolean reportLaunched, reportPaused;
    private Thread reportWorker;
    private PublicBridge.ReportFiles.WorkLease reportLease;
    private android.os.ParcelFileDescriptor reportInput;
    private android.net.Uri reportURI;
    private final Runnable reportDeadline = () -> finishReport(2);
    private void revokeReport() {
        if (reportURI != null) {
            revokeUriPermission(reportURI, Intent.FLAG_GRANT_READ_URI_PERMISSION);
            PublicBridge.ReportFiles.revoke(reportURI.getLastPathSegment()); reportURI=null;
        }
    }
    private void abandonReportPreparation() {
        PublicBridge.ReportFiles.cancelWork(reportLease);
        handler.removeCallbacks(reportDeadline); pendingReport=null; reportLaunched=false; reportPaused=false;
        android.os.ParcelFileDescriptor input=reportInput;
        if(input!=null) try { input.close(); } catch(IOException ignored) { }
        if(reportWorker!=null) reportWorker.interrupt();
    }
    private static void reportBoundary(String stage, Throwable error) {
        android.util.Log.i("FieldLogShareR1702",stage+(error==null ? "" : " exceptionClass="+error.getClass().getSimpleName()));
    }
    // A small trusted service packet, independent of Mixer UI events.
    public int reportRequest(long capturedContext, byte[] request, byte[] path, long size, int descriptor) {
        reportBoundary("request-enter",null);
        // A failed completion post cannot leave a dead per-Activity worker as an admission lock.
        if (Looper.myLooper()==Looper.getMainLooper() && reportWorker!=null && !reportWorker.isAlive()) {
            reportWorker=null; reportInput=null;
        }
        if (Looper.myLooper()!=Looper.getMainLooper() || destroyed || failed || capturedContext!=context ||
            pendingReport!=null || reportWorker!=null || request==null || request.length!=36 ||
            path==null || path.length==0 || path.length>4096 || size<=0 || size>PublicBridge.ReportFiles.MAX_BYTES || descriptor<0) { reportBoundary("request-admission-refused",null); return 1; }
        PublicBridge.ReportFiles.WorkLease reserved=null;
        String requestStage="request-token";
        try {
            String uuid=new String(request,java.nio.charset.StandardCharsets.US_ASCII);
            if (!java.util.UUID.fromString(uuid).toString().toUpperCase(java.util.Locale.ROOT).equals(uuid)) { reportBoundary("request-token-refused",null); return 1; }
            final String token=uuid.toLowerCase(java.util.Locale.ROOT);
            final String exportPath=new String(path,java.nio.charset.StandardCharsets.UTF_8);
            if (!Arrays.equals(exportPath.getBytes(java.nio.charset.StandardCharsets.UTF_8),path)) { reportBoundary("request-encoding-refused",null); return 1; }
            final byte[] captured=request.clone();
            requestStage="request-reserve";
            reserved=PublicBridge.ReportFiles.reserveWork();
            if (reserved==null) { reportBoundary("request-reserve-refused",null); return 1; }
            final PublicBridge.ReportFiles.WorkLease lease=reserved;
            reportLease=lease;
            requestStage="request-descriptor";
            final android.os.ParcelFileDescriptor input=android.os.ParcelFileDescriptor.fromFd(descriptor);
            reportInput=input;
            pendingReport=captured; reportContext=capturedContext; reportInput=input; reportLaunched=false; reportPaused=false;
            reportWorker=new Thread(() -> {
                java.io.File copied=null;
                String stage="worker-source";
                reportBoundary(stage,null);
                try (android.os.ParcelFileDescriptor owned=input) {
                    java.io.File source=PublicBridge.ReportFiles.source(getFilesDir(),exportPath,size);
                    stage="worker-stat-before";
                    android.system.StructStat before=android.system.Os.fstat(owned.getFileDescriptor());
                    stage="worker-stat-named";
                    android.system.StructStat named=android.system.Os.lstat(source.getPath());
                    stage="worker-identity";
                    if (!android.system.OsConstants.S_ISREG(before.st_mode) || before.st_size!=size ||
                        before.st_dev!=named.st_dev || before.st_ino!=named.st_ino) throw new IOException("report identity changed");
                    try (InputStream stream=new android.os.ParcelFileDescriptor.AutoCloseInputStream(owned)) {
                        stage="worker-copy";
                        copied=PublicBridge.ReportFiles.copy(new java.io.File(getCacheDir(),"fieldlog-report-share"),stream,size);
                        stage="worker-stat-after";
                        android.system.StructStat after=android.system.Os.fstat(owned.getFileDescriptor());
                        if (before.st_dev!=after.st_dev || before.st_ino!=after.st_ino || before.st_size!=after.st_size ||
                            before.st_mtim.tv_sec!=after.st_mtim.tv_sec || before.st_mtim.tv_nsec!=after.st_mtim.tv_nsec ||
                            before.st_ctim.tv_sec!=after.st_ctim.tv_sec || before.st_ctim.tv_nsec!=after.st_ctim.tv_nsec) throw new IOException("report source changed");
                    }
                    stage="worker-prepare";
                    final java.io.File immutable=copied;
                    if (PublicBridge.ReportFiles.prepareWork(lease,immutable)) {
                        copied=null;
                        stage="worker-post";
                        reportBoundary(stage,null);
                        if (!handler.post(() -> {
                            if (PublicBridge.ReportFiles.takePrepared(lease,immutable))
                                reportPrepared(lease,capturedContext,captured,token,immutable,size);
                        })) PublicBridge.ReportFiles.cancelWork(lease);
                    } else { PublicBridge.ReportFiles.cancelWork(lease); copied=null; }
                } catch (Exception | Error error) {
                    reportBoundary(stage,error);
                    PublicBridge.ReportFiles.cancelWork(lease);
                    try { handler.post(() -> { if(reportLease==lease && Arrays.equals(pendingReport,captured)) finishReport(2); }); }
                    catch (RuntimeException | OutOfMemoryError unavailable) { /* Local cleanup still completes. */ }
                } finally {
                    PublicBridge.ReportFiles.workerFinished(lease);
                    try { handler.post(() -> { if(reportLease==lease && reportInput==input) { reportInput=null; reportWorker=null; reportLease=null; } }); }
                    catch (RuntimeException | OutOfMemoryError unavailable) { /* Admission observes actual thread death. */ }
                }
            },"FieldLog-report");
            PublicBridge.ReportFiles.bindWorker(lease,reportWorker);
            requestStage="request-worker-start";
            reportWorker.start();
            if (!handler.postDelayed(reportDeadline,30000)) { abandonReportPreparation(); return 1; }
            return 0;
        } catch (Exception | OutOfMemoryError error) {
            reportBoundary(requestStage,error);
            abandonReportPreparation();
            if (reserved!=null) {
                PublicBridge.ReportFiles.failedBeforeStart(reserved);
                if (reportWorker==null || reportWorker.getState()==Thread.State.NEW) {
                    reportInput=null; reportWorker=null; reportLease=null;
                }
            }
            return 1;
        }
    }
    private void reportPrepared(PublicBridge.ReportFiles.WorkLease lease,long capturedContext,byte[] token,String opaque,java.io.File file,long size) {
        if (destroyed || failed || capturedContext!=context || !Arrays.equals(pendingReport,token)) { PublicBridge.ReportFiles.cancelWork(lease); return; }
        handler.removeCallbacks(reportDeadline);
        reportBoundary("prepared-enter",null);
        String stage="prepared-revoke";
        boolean published=false;
        try {
            revokeReport();
            stage="prepared-publish";
            PublicBridge.ReportFiles.publish(opaque,file,size,android.os.SystemClock.elapsedRealtime()); published=true;
            stage="prepared-uri";
            reportURI=PublicBridge.ReportProvider.uri(opaque);
            stage="prepared-chooser";
            Intent chooser=PublicBridge.ReportIntent.chooser(reportURI);
            stage="prepared-start-activity";
            startActivity(chooser); reportLaunched=true;
            reportBoundary("prepared-started",null);
            stage="prepared-report-jni";
            if (PublicBridge.report(context,token,1)!=0) fail();
            final android.net.Uri admitted=reportURI;
            if (!handler.postDelayed(() -> { if(admitted.equals(reportURI)) { revokeReport(); if(pendingReport!=null) finishReport(2); } },PublicBridge.ReportFiles.LIFETIME_MS)) {
                revokeReport(); finishReport(2);
            }
        } catch (Exception | OutOfMemoryError error) { reportBoundary(stage,error); PublicBridge.ReportFiles.revoke(opaque); if(!published) PublicBridge.ReportFiles.cancelWork(lease); reportURI=null; finishReport(2); }
    }
    private void finishReport(int result) {
        PublicBridge.ReportFiles.cancelWork(reportLease);
        handler.removeCallbacks(reportDeadline);
        byte[] token=pendingReport; pendingReport=null; reportLaunched=false; reportPaused=false;
        android.os.ParcelFileDescriptor input=reportInput;
        if(input!=null) try { input.close(); } catch(IOException ignored) { }
        if(reportWorker!=null) reportWorker.interrupt();
        if(!destroyed && !failed && token!=null && reportContext==context && PublicBridge.report(context,token,result)!=0) fail();
    }
    private static final class CapturedEvent {
        final long context; final AndroidUINativeSurface surface; final byte[] owner, envelope;
        CapturedEvent(long context, AndroidUINativeSurface surface, byte[] owner, byte[] envelope) {
            this.context = context; this.surface = surface; this.owner = owner.clone(); this.envelope = envelope.clone();
        }
    }
    private final ArrayDeque<CapturedEvent> events = new ArrayDeque<>();
    private int eventBytes = 2; // JSON array delimiters, plus comma per subsequent event.
    private int readiness;
    private byte[] pendingPhoto;
    private boolean photoResultClaimed;
    private long photoContext;
    private int photoCode, nextPhotoCode = 100;
    private volatile CancellationSignal photoCancellation;
    private volatile InputStream photoStream;
    private volatile Thread photoThread;
    private static final int PHOTO_SOURCE_MAX = 16 * 1024 * 1024, PHOTO_JPEG_MAX = 6 * 1024 * 1024;
    private final Runnable photoDeadline = () -> {
        cancelPhotoWorker();
        if (pendingPhoto != null) finishPhoto(photoContext, pendingPhoto, 4, new byte[0]);
    };
    private static final class LimitedBytes extends ByteArrayOutputStream {
        private final int limit;
        LimitedBytes(int limit) { this.limit = limit; }
        @Override public synchronized void write(int value) {
            if (count >= limit) throw new IllegalArgumentException("image size limit");
            super.write(value);
        }
        @Override public synchronized void write(byte[] value, int offset, int length) {
            if (length < 0 || length > limit - count) throw new IllegalArgumentException("image size limit");
            super.write(value, offset, length);
        }
    }
    // Called only by the separate app-native service after public UI admission.
    public int photoRequest(long capturedContext, byte[] request) {
        if (Looper.myLooper() != Looper.getMainLooper() || destroyed || failed || capturedContext != context ||
                request == null || request.length != 36) return 1;
        final byte[] token = request.clone();
        return handler.post(() -> launchPhoto(capturedContext, token)) ? 0 : 1;
    }
    @SuppressWarnings("deprecation")
    private void launchPhoto(long capturedContext, byte[] request) {
        if (destroyed || failed || capturedContext != context) return;
        if (pendingPhoto != null || (photoThread != null && photoThread.isAlive()) || nextPhotoCode > 65534) {
            if (PublicBridge.photo(capturedContext, request, 4, new byte[0]) != 0) fail();
            return;
        }
        pendingPhoto = request; photoResultClaimed = false; photoContext = capturedContext; photoCode = nextPhotoCode++;
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                .setType("image/*").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try { startActivityForResult(intent, photoCode); }
        catch (SecurityException error) { finishPhoto(capturedContext, request, 1, new byte[0]); }
        catch (RuntimeException error) { finishPhoto(capturedContext, request, 4, new byte[0]); }
    }
    @Override @SuppressWarnings("deprecation")
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (destroyed || failed || pendingPhoto == null || requestCode != photoCode || photoResultClaimed) return;
        // Claim before any result handling or worker creation, on the main thread.
        photoResultClaimed = true;
        final byte[] request = pendingPhoto.clone(); final long capturedContext = photoContext;
        if (resultCode != RESULT_OK) { finishPhoto(capturedContext, request, 0, new byte[0]); return; }
        final Uri uri = data == null ? null : data.getData();
        if (uri == null || !"content".equals(uri.getScheme())) { finishPhoto(capturedContext, request, 2, new byte[0]); return; }
        final CancellationSignal cancellation = new CancellationSignal(); photoCancellation = cancellation;
        photoThread = new Thread(() -> {
            int result = 2; byte[] jpeg = new byte[0]; Bitmap bitmap = null;
            try {
                LimitedBytes source = new LimitedBytes(PHOTO_SOURCE_MAX);
                // One provider open/read. Decode only the bounded owned copy.
                try (AssetFileDescriptor descriptor = getContentResolver().openAssetFileDescriptor(uri, "r", cancellation)) {
                    if (descriptor == null || descriptor.getLength() > PHOTO_SOURCE_MAX) throw new IllegalArgumentException("image size limit");
                    try (InputStream stream = descriptor.createInputStream()) {
                        photoStream = stream; byte[] buffer = new byte[16384]; int count;
                        while ((count = stream.read(buffer)) != -1) {
                            cancellation.throwIfCanceled(); source.write(buffer, 0, count);
                        }
                    } finally { photoStream = null; }
                }
                cancellation.throwIfCanceled();
                bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(source.toByteArray())), (decoder, info, input) -> {
                    int width = info.getSize().getWidth(), height = info.getSize().getHeight();
                    if (width <= 0 || height <= 0 || width > 20000 || height > 20000 || (long)width * height > 100000000L)
                        throw new IllegalArgumentException("image dimensions limit");
                    double scale = Math.min(1.0, 2048.0 / Math.max(width, height));
                    decoder.setTargetSize(Math.max(1, (int)(width * scale)), Math.max(1, (int)(height * scale)));
                    decoder.setAllocator(ImageDecoder.ALLOCATOR_SOFTWARE);
                    decoder.setOnPartialImageListener(error -> false);
                });
                cancellation.throwIfCanceled();
                LimitedBytes output = new LimitedBytes(PHOTO_JPEG_MAX);
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 85, output)) throw new IOException("image encoding failed");
                jpeg = output.toByteArray();
                if (jpeg.length < 3 || jpeg.length > PHOTO_JPEG_MAX || (jpeg[0]&255)!=255 || (jpeg[1]&255)!=216 || (jpeg[2]&255)!=255)
                    throw new IOException("invalid JPEG output");
                cancellation.throwIfCanceled(); result = 5;
            } catch (SecurityException error) { result = 1; }
            catch (IllegalArgumentException error) { result = 3; }
            catch (IOException | RuntimeException error) { result = 2; }
            finally { if (bitmap != null) bitmap.recycle(); }
            final int outcome = result; final byte[] ownedJPEG = result == 5 ? jpeg.clone() : new byte[0];
            handler.post(() -> finishPhoto(capturedContext, request, outcome, ownedJPEG));
        }, "FieldLog-photo");
        photoThread.start();
        if (!handler.postDelayed(photoDeadline, 30000)) { cancelPhotoWorker(); finishPhoto(capturedContext, request, 4, new byte[0]); }
    }
    private void cancelPhotoWorker() {
        CancellationSignal cancellation = photoCancellation; if (cancellation != null) cancellation.cancel();
        InputStream stream = photoStream;
        if (stream != null) try { stream.close(); } catch (IOException ignored) { }
        Thread worker = photoThread; if (worker != null) worker.interrupt();
    }
    private void finishPhoto(long capturedContext, byte[] request, int result, byte[] jpeg) {
        if (destroyed || failed || capturedContext != context || pendingPhoto == null || !Arrays.equals(request, pendingPhoto)) return;
        handler.removeCallbacks(photoDeadline); pendingPhoto = null;
        // Flush genuine UI events before the separate service completion.
        if (!events.isEmpty()) drainEvents();
        if (!destroyed && !failed && PublicBridge.photo(capturedContext, request, result, jpeg) != 0) fail();
    }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state); root = new FrameLayout(this); setContentView(root);
        configureSystemBarAppearance();
        if (!handler.post(this::openWhenReady)) throw new IllegalStateException("host queue unavailable");
    }
    private void configureSystemBarAppearance() {
        // The manifest fixes this app window to Theme.Material.Light.NoActionBar.
        if (Build.VERSION.SDK_INT >= 30) {
            int lightBars = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS |
                WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
            getWindow().getInsetsController().setSystemBarsAppearance(lightBars, lightBars);
        } else {
            configureLegacySystemBarAppearance();
        }
    }
    @SuppressWarnings("deprecation")
    private void configureLegacySystemBarAppearance() {
        View decor = getWindow().getDecorView();
        decor.setSystemUiVisibility(decor.getSystemUiVisibility() |
            View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
    }
    private void openWhenReady() {
        if (destroyed || failed) return;
        if (root.getWidth() <= 0 || root.getHeight() <= 0 || root.getRootWindowInsets() == null || !root.hasWindowFocus()) {
            if (++readiness > 625 || !handler.postDelayed(this::openWhenReady, 16)) fail();
            return;
        }
        surface = new AndroidUINativeSurface(this, root, AndroidUIProfile.MEASURED_MULTILINE_LONG_NOTES_V4, this::enqueue);
        context = PublicBridge.open(this, surface.profile().name());
        if (context <= 0) fail();
    }
    private void enqueue(byte[] capturedOwner, byte[] envelope) {
        if (Looper.myLooper() != Looper.getMainLooper() || destroyed || failed || draining || context <= 0 || surface == null ||
            owner == null || capturedOwner == null || !Arrays.equals(capturedOwner, owner) || envelope == null ||
            envelope.length == 0 || envelope.length > MAX_BYTES || events.size() >= MAX_EVENTS ||
            eventBytes + envelope.length + (events.isEmpty() ? 0 : 1) > MAX_BYTES) {
            deferQueueFailure(); throw new IllegalStateException("native event queue unavailable");
        }
        CapturedEvent first = events.peekFirst();
        if (first != null && (first.context != context || first.surface != surface || !Arrays.equals(first.owner, capturedOwner))) {
            deferQueueFailure(); throw new IllegalStateException("native event authority changed");
        }
        eventBytes += envelope.length + (events.isEmpty() ? 0 : 1);
        events.addLast(new CapturedEvent(context, surface, capturedOwner, envelope));
        if (!drainScheduled) {
            drainScheduled = true;
            if (!handler.post(this::drainEvents)) {
                deferQueueFailure(); throw new IllegalStateException("host queue unavailable");
            }
        }
    }
    private void drainEvents() {
        drainScheduled = false;
        if (destroyed || failed) { invalidateEvents(); return; }
        if (events.isEmpty()) return;
        draining = true;
        try {
            surface.gateInput();
            CapturedEvent first = events.peekFirst();
            for (CapturedEvent event : events) {
                if (event.context != context || event.surface != surface || !Arrays.equals(event.owner, owner) ||
                    event.context != first.context || event.surface != first.surface || !Arrays.equals(event.owner, first.owner)) {
                    fail(); return;
                }
            }
            byte[] batch = new byte[eventBytes]; int offset = 0; batch[offset++] = '[';
            for (CapturedEvent event : events) {
                if (offset > 1) batch[offset++] = ',';
                System.arraycopy(event.envelope, 0, batch, offset, event.envelope.length); offset += event.envelope.length;
            }
            batch[offset++] = ']';
            if (offset != batch.length) { fail(); return; }
            invalidateEvents();
            if (PublicBridge.event(first.context, first.owner, batch) != 0) fail();
            // Only the ensuing validated surface.install reopens native input.
        } catch (RuntimeException error) {
            fail(); throw error;
        } finally { draining = false; }
    }
    // Native callbacks only record/copy and post. Even rejected input must
    // unwind its editor lease before the app asks the surface to gate.
    private void deferQueueFailure() {
        boolean first = !failed;
        failed = true; invalidateEvents();
        if (first) handler.post(this::fail);
    }
    private void invalidateEvents() { events.clear(); eventBytes = 2; }
    public int surface(long capturedContext, int operation, byte[] token, byte[] packet, byte[] descriptor) {
        if (Looper.myLooper() != Looper.getMainLooper()) return 1;
        // During open, the native bridge has not returned this lifetime's id.
        if (context == 0 && operation == 0 && !destroyed && !failed) context = capturedContext;
        if (capturedContext != context || surface == null || (destroyed && operation != 2)) return 1;
        try {
            switch (operation) {
                case 0: if (owner != null) return 1; surface.activate(token); owner = token.clone(); break;
                case 1: surface.install(new AndroidUINativeSurface.Frame(token, packet, descriptor)); break;
                case 2: invalidateEvents(); surface.revoke(token); owner = null; break;
                default: return 1;
            }
            return 0;
        } catch (RuntimeException error) { android.util.Log.e("MixerAndroidHost", "Native surface operation failed: " + operation, error); fail(); return 1; }
    }
    private void fail() { failed = true; invalidateEvents(); if (surface != null) surface.gateInput(); }
    @Override public void onResume() { super.onResume(); if (surface != null) surface.onResume(); if(reportPaused && reportLaunched) finishReport(0); }
    @Override public void onPause() { if(reportLaunched) reportPaused=true; if (surface != null) surface.onPause(); super.onPause(); }
    @Override public void onStop() { if (surface != null) surface.onStop(); super.onStop(); }
    @Override public void onDestroy() {
        destroyed = true; finishReport(2); revokeReport(); pendingPhoto = null; cancelPhotoWorker();
        Thread worker = photoThread;
        if (worker != null) try { worker.join(100); } catch (InterruptedException error) { Thread.currentThread().interrupt(); }
        // A provider that ignores cancellation may outlive this bounded join;
        // destroyed/context/request fencing prevents every late mutation.
        invalidateEvents(); handler.removeCallbacksAndMessages(null);
        if (context > 0 && PublicBridge.close(context) != 0) failed = true;
        if (surface != null) surface.close(); super.onDestroy();
    }
}
