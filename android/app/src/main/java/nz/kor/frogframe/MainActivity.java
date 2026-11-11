package nz.kor.frogframe;

import android.app.*;
import android.os.*;
import android.content.*;
import android.graphics.*;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import androidx.exifinterface.media.ExifInterface;
import android.view.*;
import android.widget.*;
import android.text.InputType;
import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;

public class MainActivity extends Activity {
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final ExecutorService syncIo = Executors.newSingleThreadExecutor();
    private final OkHttpClient updatesClient = new OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false).build();
    private WebSocket updates;
    private int watchGeneration;
    private long reconnectDelay = 2000;
    private boolean connected, syncRunning, syncAgain, hasSynced;
    private String currentPhoto;
    private Toast changeToast;
    private final UploadGroups uploadGroups = new UploadGroups();
    private int uploadCompletionVersion;
    private final Runnable sync = this::refreshLiveList;
    private final Runnable reconnect = this::connectUpdates;
    private final Runnable poll = new Runnable() {
        @Override public void run() {
            queueSync();
            ui.postDelayed(this, connected ? 60000 : 15000);
        }
    };
    private final List<String> photos = new ArrayList<>();
    private android.content.SharedPreferences prefs;
    private FrameLayout root;
    private ImageView image;
    private ImageView previousImage;
    private TextView status;
    private boolean active, settingsOpen;
    private volatile int generation;
    private int position = -1;
    private long lastRefresh;
    private String endpoint, token;
    private int seconds;
    private boolean crop, crossfade;
    private final Runnable advance = () -> next(false);
    private static final long MAX_FILE = 40L * 1024 * 1024;
    private static final long MAX_CACHE = 256L * 1024 * 1024;
    private static final long CROSSFADE_MS = 600;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        prefs = getSharedPreferences("settings", MODE_PRIVATE);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        root = new SlideshowView();
        root.setBackgroundColor(Color.BLACK);
        previousImage = new ImageView(this);
        previousImage.setBackgroundColor(Color.BLACK);
        root.addView(previousImage, new FrameLayout.LayoutParams(-1, -1));
        image = new ImageView(this);
        image.setBackgroundColor(Color.BLACK);
        root.addView(image, new FrameLayout.LayoutParams(-1, -1));
        status = new TextView(this);
        status.setTextColor(Color.LTGRAY);
        status.setTextSize(20);
        status.setGravity(Gravity.CENTER);
        status.setPadding(40, 40, 40, 40);
        root.addView(status, new FrameLayout.LayoutParams(-1, -1));
        setContentView(root);
        readSettings();
    }

    private class SlideshowView extends FrameLayout {
        private int direction = 1;
        SlideshowView() {
            super(MainActivity.this);
            setClickable(true);
            setOnLongClickListener(view -> { settings(); return true; });
        }
        // View handles click detection and calls our performClick, including accessibility clicks.
        @android.annotation.SuppressLint("ClickableViewAccessibility")
        @Override public boolean onTouchEvent(MotionEvent event) {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
                direction = event.getX() < getWidth() / 2f ? -1 : 1;
            }
            return super.onTouchEvent(event);
        }
        @Override public boolean performClick() {
            super.performClick();
            int step = direction;
            direction = 1;
            show(false, step);
            return true;
        }
    }

    private void readSettings() {
        endpoint = prefs.getString("endpoint", "");
        token = prefs.getString("token", "");
        seconds = prefs.getInt("seconds", 15);
        crop = prefs.getBoolean("crop", false);
        crossfade = prefs.getBoolean("crossfade", true);
        image.setScaleType(crop ? ImageView.ScaleType.CENTER_CROP : ImageView.ScaleType.FIT_CENTER);
        previousImage.setScaleType(image.getScaleType());
    }

    private void finishTransition() {
        image.animate().cancel();
        image.setAlpha(1f);
        previousImage.setImageDrawable(null);
    }

    private void clearImage() {
        finishTransition();
        image.setImageDrawable(null);
    }

    private void displayImage(Bitmap bitmap) {
        Drawable previous = image.getDrawable();
        finishTransition();
        // Use a separate drawable so ImageView cannot reuse and change the outgoing bitmap.
        image.setImageDrawable(new BitmapDrawable(getResources(), bitmap));
        if (crossfade && previous != null) {
            previousImage.setImageDrawable(previous);
            image.setAlpha(0f);
            image.animate().alpha(1f).setDuration(CROSSFADE_MS)
                .setInterpolator(new android.view.animation.AccelerateDecelerateInterpolator())
                .withEndAction(() -> previousImage.setImageDrawable(null)).start();
        }
    }

    @Override protected void onResume() {
        super.onResume(); active = true; immersive();
        photos.clear(); position = -1; lastRefresh = 0; hasSynced = false; currentPhoto = null;
        if (endpoint.isEmpty()) settings(); else next(true);
        startUpdates();
    }
    @Override protected void onPause() {
        super.onPause(); active = false; generation++; stopUpdates(); finishTransition(); ui.removeCallbacksAndMessages(null);
    }
    @Override protected void onDestroy() {
        super.onDestroy(); io.shutdownNow(); syncIo.shutdownNow();
        updatesClient.dispatcher().executorService().shutdown();
        updatesClient.connectionPool().evictAll();
    }

    private void startUpdates() {
        stopUpdates();
        if (!active || endpoint.isEmpty()) return;
        connectUpdates();
        ui.postDelayed(poll, 15000);
    }

    private void stopUpdates() {
        watchGeneration++; connected = false; syncRunning = false; syncAgain = false;
        ui.removeCallbacks(sync); ui.removeCallbacks(reconnect); ui.removeCallbacks(poll);
        if (updates != null) { updates.cancel(); updates = null; }
    }

    private void connectUpdates() {
        if (!active || endpoint.isEmpty() || updates != null) return;
        final int watch = watchGeneration;
        Request request = new Request.Builder().url(endpoint + "/updates")
            .header("Authorization", "Bearer " + token).build();
        updates = updatesClient.newWebSocket(request, new WebSocketListener() {
            @Override public void onOpen(WebSocket socket, Response response) {
                ui.post(() -> { if (watch != watchGeneration) return; connected = true; reconnectDelay = 2000; queueSync(); });
            }
            @Override public void onMessage(WebSocket socket, String message) {
                ui.post(() -> {
                    if (watch != watchGeneration) return;
                    try {
                        JSONObject event = new JSONObject(message);
                        String type = event.optString("type");
                        long now = SystemClock.elapsedRealtime();
                        if (type.equals("upload-started")) uploadGroups.progress(event.optString("group"), now);
                        else if (type.equals("upload-finished")) {
                            uploadGroups.finish(event.optString("group"), event.optInt("added", 0), now);
                            uploadCompletionVersion++;
                        }
                        else if (type.equals("changed")) uploadGroups.progress(event.optString("uploadGroup"), now);
                    } catch (JSONException ignored) { }
                    queueSync();
                });
            }
            @Override public void onClosing(WebSocket socket, int code, String reason) {
                socket.close(code == 1005 ? 1000 : code, reason);
            }
            @Override public void onClosed(WebSocket socket, int code, String reason) { retry(); }
            @Override public void onFailure(WebSocket socket, Throwable error, Response response) { retry(); }
            private void retry() {
                ui.post(() -> {
                    if (watch != watchGeneration || !active) return;
                    connected = false; updates = null;
                    ui.removeCallbacks(reconnect); ui.postDelayed(reconnect, reconnectDelay);
                    reconnectDelay = Math.min(30000, reconnectDelay * 2);
                });
            }
        });
    }

    private void queueSync() {
        if (!active || endpoint.isEmpty()) return;
        ui.removeCallbacks(sync);
        ui.postDelayed(sync, 250);
    }

    private void refreshLiveList() {
        if (!active || endpoint.isEmpty()) return;
        if (settingsOpen || syncRunning) { syncAgain = true; return; }
        syncRunning = true; syncAgain = false;
        final int watch = watchGeneration;
        final String server = endpoint, auth = token;
        final int completionVersion = uploadCompletionVersion;
        syncIo.execute(() -> {
            List<String> fresh = null;
            try { fresh = manifest(server, auth); } catch (Exception ignored) { }
            final List<String> result = fresh;
            ui.post(() -> {
                if (watch != watchGeneration || !active) return;
                syncRunning = false;
                if (result != null) {
                    applyLiveList(result);
                    if (completionVersion == uploadCompletionVersion) {
                        for (String notice : uploadGroups.completedNotices()) showChangeNotice(notice);
                    }
                }
                if (syncAgain) { syncAgain = false; queueSync(); }
            });
        });
    }

    private void announceChanges(List<String> fresh) {
        String message = hasSynced && !uploadGroups.suppressChanges(SystemClock.elapsedRealtime()) ? Playlist.notice(photos, fresh) : "";
        hasSynced = true;
        showChangeNotice(message);
    }

    private void showChangeNotice(String message) {
        if (!message.isEmpty()) {
            if (changeToast != null) changeToast.cancel();
            changeToast = Toast.makeText(this, message, Toast.LENGTH_SHORT);
            changeToast.show();
        }
    }

    private void applyLiveList(List<String> fresh) {
        lastRefresh = System.currentTimeMillis();
        announceChanges(fresh);
        if (!fresh.isEmpty() && new HashSet<>(photos).equals(new HashSet<>(fresh))) return;
        int oldPosition = position;
        List<String> ordered = Playlist.merge(photos, fresh);
        finishTransition();
        generation++; // Discard an image load that used the old list.
        photos.clear(); photos.addAll(ordered);
        position = currentPhoto == null ? -1 : photos.indexOf(currentPhoto);
        ui.removeCallbacks(advance);
        if (photos.isEmpty()) {
            currentPhoto = null; clearImage();
            status.setText("No images in the bucket. Add photos to start the slideshow.\n\nLong press for settings.");
            status.setVisibility(View.VISIBLE);
        } else if (position >= 0 && image.getDrawable() != null) {
            ui.postDelayed(advance, seconds * 1000L);
        } else {
            currentPhoto = null; clearImage();
            position = Math.min(Math.max(oldPosition, 0), photos.size()) - 1;
            show(false, 1);
        }
    }
    @Override public void onWindowFocusChanged(boolean focus) {
        super.onWindowFocusChanged(focus); if (focus) immersive();
    }
    private void immersive() {
        if (Build.VERSION.SDK_INT >= 30) {
            getWindow().setDecorFitsSystemWindows(false);
            WindowInsetsController c = getWindow().getInsetsController();
            if (c != null) {
                c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
                c.hide(WindowInsets.Type.systemBars());
            }
        } else {
            getWindow().getDecorView().setSystemUiVisibility(5894);
        }
    }

    private void settings() {
        if (settingsOpen) return;
        settingsOpen = true; generation++; ui.removeCallbacks(advance);
        finishTransition();
        LinearLayout form = new LinearLayout(this);
        form.setOrientation(LinearLayout.VERTICAL); form.setPadding(32, 8, 32, 8);
        EditText address = field(form, "Photo server URL (HTTPS)", endpoint, InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        EditText password = field(form, "Viewer token", token, InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        EditText duration = field(form, "Seconds per image", "" + seconds, InputType.TYPE_CLASS_NUMBER);
        CheckBox fill = new CheckBox(this); fill.setText(R.string.fill); fill.setChecked(crop); form.addView(fill);
        CheckBox fade = new CheckBox(this); fade.setText(R.string.crossfade); fade.setChecked(crossfade); form.addView(fade);
        TextView hint = new TextView(this); hint.setText(R.string.settings_hint); form.addView(hint);
        ScrollView scroll = new ScrollView(this); scroll.addView(form);
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("Frogframe").setView(scroll)
            .setPositiveButton("Start slideshow", null).setNegativeButton("Cancel", null).create();
        dialog.setOnDismissListener(d -> {
            settingsOpen = false; immersive();
            if (active && !endpoint.isEmpty()) { next(true); startUpdates(); }
        });
        dialog.setOnShowListener(d -> dialog.getButton(-1).setOnClickListener(v -> {
            String url = address.getText().toString().trim().replaceAll("/+$", "");
            try {
                URI parsed = new URI(url);
                if (!"https".equalsIgnoreCase(parsed.getScheme()) || parsed.getHost() == null || parsed.getRawUserInfo() != null || parsed.getRawQuery() != null || parsed.getRawFragment() != null || !(parsed.getPath().isEmpty() || parsed.getPath().equals("/"))) throw new Exception();
            } catch (Exception e) { address.setError("Enter an HTTPS server URL without a path."); return; }
            int delay;
            try { delay = Integer.parseInt(duration.getText().toString()); if (delay < 2 || delay > 3600) throw new Exception(); }
            catch (Exception e) { duration.setError("Use 2 to 3600 seconds."); return; }
            String newToken = password.getText().toString().trim();
            if (newToken.isEmpty()) { password.setError("Enter the viewer token."); return; }
            boolean changed = !url.equals(endpoint) || !newToken.equals(token);
            prefs.edit().putString("endpoint", url).putString("token", newToken).putInt("seconds", delay)
                .putBoolean("crop", fill.isChecked()).putBoolean("crossfade", fade.isChecked()).apply();
            readSettings();
            if (changed) {
                photos.clear(); position = -1; lastRefresh = 0; hasSynced = false; currentPhoto = null; clearImage();
            }
            dialog.dismiss();
        }));
        dialog.show();
    }

    private EditText field(LinearLayout form, String label, String value, int type) {
        TextView caption = new TextView(this); caption.setText(label); form.addView(caption);
        EditText edit = new EditText(this); edit.setSingleLine(true); edit.setInputType(type);
        if ((type & InputType.TYPE_TEXT_VARIATION_PASSWORD) == InputType.TYPE_TEXT_VARIATION_PASSWORD) {
            edit.setTransformationMethod(android.text.method.PasswordTransformationMethod.getInstance());
        }
        edit.setText(value); form.addView(edit); return edit;
    }

    private void next(boolean forceRefresh) { show(forceRefresh, 1); }

    private void show(boolean forceRefresh, int direction) {
        if (!active || settingsOpen || endpoint.isEmpty()) return;
        ui.removeCallbacks(advance);
        final int run = ++generation;
        final String server = endpoint, auth = token;
        final boolean refresh = forceRefresh || photos.isEmpty() || System.currentTimeMillis() - lastRefresh > 300000;
        final ArrayList<String> current = new ArrayList<>(photos);
        final int start = position;
        final int width = Math.max(root.getWidth(), 1920), height = Math.max(root.getHeight(), 1200);
        if (image.getDrawable() == null) { status.setText("Loading photos…\n\nLong press for settings."); status.setVisibility(View.VISIBLE); }
        io.execute(() -> {
            List<String> list = current;
            long refreshed = 0;
            try {
                if (refresh) {
                    try { list = manifest(server, auth); refreshed = System.currentTimeMillis(); }
                    catch (Exception e) {
                        if (e instanceof AuthException) throw e;
                        if (list.isEmpty()) list = savedManifest(server, auth);
                        if (list.isEmpty()) throw e;
                    }
                    list = Playlist.merge(current, list);
                }
                if (list.isEmpty()) {
                    ui.post(() -> { if (run == generation && active) applyLiveList(Collections.emptyList()); });
                    return;
                }
                Bitmap bitmap = null;
                int anchor = start >= 0 && start < current.size() ? list.indexOf(current.get(start)) : -1;
                int nextPosition = anchor >= 0 ? anchor + direction : 0;
                int selectedPosition = nextPosition;
                // Bound retries so a large bucket of broken images cannot block settings.
                for (int tried = 0; tried < Math.min(list.size(), 10); tried++) {
                    if (run != generation) return;
                    selectedPosition = Math.floorMod(nextPosition, list.size());
                    String url = list.get(selectedPosition);
                    try { bitmap = loadImage(url, server, auth, width, height); break; }
                    catch (AuthException e) { throw e; }
                    catch (IOException ignored) { }
                    nextPosition += direction;
                }
                final Bitmap result = bitmap;
                final List<String> resultList = list;
                final int resultPosition = selectedPosition;
                final long refreshTime = refreshed;
                ui.post(() -> {
                    if (run != generation || !active) { if (result != null) result.recycle(); return; }
                    announceChanges(resultList);
                    photos.clear(); photos.addAll(resultList); position = resultPosition;
                    if (refreshTime > 0) lastRefresh = refreshTime;
                    if (result != null) { currentPhoto = resultList.get(resultPosition); displayImage(result); status.setVisibility(View.GONE); }
                    else if (image.getDrawable() == null) status.setText("Cannot load photos. Check the connection and image files.\n\nLong press for settings.");
                    ui.postDelayed(advance, result != null ? seconds * 1000L : 15000);
                });
            } catch (Exception e) {
                final String message = e instanceof AuthException ? "Access denied. Check the viewer token." : e.getMessage();
                ui.post(() -> {
                    if (run != generation || !active) return;
                    if (image.getDrawable() == null) status.setText(getString(R.string.connection_error, message == null ? "Cannot connect to the photo server." : message));
                    ui.postDelayed(advance, 30000);
                });
            }
        });
    }

    private static class AuthException extends IOException { }
    private HttpURLConnection connect(String address, String server, String auth) throws Exception {
        URI target = new URI(address), origin = new URI(server);
        if (!"https".equalsIgnoreCase(target.getScheme()) || !origin.getHost().equalsIgnoreCase(target.getHost()) || origin.getPort() != target.getPort()) throw new IOException("Invalid photo URL.");
        HttpURLConnection c = (HttpURLConnection) target.toURL().openConnection();
        c.setInstanceFollowRedirects(false); c.setConnectTimeout(15000); c.setReadTimeout(20000);
        c.setRequestProperty("Authorization", "Bearer " + auth);
        int code = c.getResponseCode();
        if (code == 401 || code == 403) { c.disconnect(); throw new AuthException(); }
        if (code != 200) { c.disconnect(); throw new IOException("Photo server returned " + code + "."); }
        return c;
    }
    private String hash(String value) throws Exception {
        StringBuilder out = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8))) out.append(String.format("%02x", b));
        return out.toString();
    }
    private File manifestFile(String server, String auth) throws Exception { return new File(getCacheDir(), hash(server + auth) + ".json"); }
    private List<String> savedManifest(String server, String auth) throws Exception {
        File file = manifestFile(server, auth);
        if (!file.exists()) return new ArrayList<>();
        try (InputStream input = new FileInputStream(file)) { return parseArray(new JSONArray(new String(read(input, 8 * 1024 * 1024), StandardCharsets.UTF_8))); }
    }
    private List<String> parseArray(JSONArray array) throws Exception {
        List<String> urls = new ArrayList<>();
        for (int i = 0; i < array.length(); i++) urls.add(array.getString(i));
        return urls;
    }
    private synchronized List<String> manifest(String server, String auth) throws Exception {
        List<String> urls = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        String cursor = null;
        do {
            String address = server + "/manifest" + (cursor == null ? "" : "?cursor=" + URLEncoder.encode(cursor, "UTF-8"));
            HttpURLConnection c = connect(address, server, auth);
            JSONObject page;
            try (InputStream in = c.getInputStream()) { page = new JSONObject(new String(read(in, 4 * 1024 * 1024), StandardCharsets.UTF_8)); }
            finally { c.disconnect(); }
            JSONArray entries = page.getJSONArray("images");
            for (int i = 0; i < entries.length(); i++) urls.add(entries.getJSONObject(i).getString("url"));
            cursor = page.isNull("cursor") ? null : page.optString("cursor", null);
            if (cursor != null && (!seen.add(cursor) || seen.size() > 100)) throw new IOException("Invalid photo list.");
        } while (cursor != null);
        File file = manifestFile(server, auth), temp = new File(file + ".tmp");
        try (OutputStream out = new FileOutputStream(temp)) { out.write(new JSONArray(urls).toString().getBytes(StandardCharsets.UTF_8)); }
        if (!temp.renameTo(file)) temp.delete();
        return urls;
    }
    private byte[] read(InputStream in, int limit) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(); byte[] buffer = new byte[16384]; int n;
        while ((n = in.read(buffer)) != -1) { if (out.size() + n > limit) throw new IOException("Response is too large."); out.write(buffer, 0, n); }
        return out.toByteArray();
    }
    private Bitmap loadImage(String address, String server, String auth, int width, int height) throws Exception {
        File file = new File(getCacheDir(), hash(server + auth + address) + ".img");
        if (!file.exists()) {
            HttpURLConnection c = connect(address, server, auth);
            File temp = new File(file + ".tmp");
            try {
                if (c.getContentLengthLong() > MAX_FILE) throw new IOException("Image is too large.");
                try (InputStream in = c.getInputStream(); OutputStream out = new FileOutputStream(temp)) {
                    byte[] buffer = new byte[16384]; long total = 0; int n;
                    while ((n = in.read(buffer)) != -1) { total += n; if (total > MAX_FILE) throw new IOException("Image is too large."); out.write(buffer, 0, n); }
                }
                if (!temp.renameTo(file)) throw new IOException("Cannot save photo.");
            } finally { c.disconnect(); temp.delete(); }
        }
        file.setLastModified(System.currentTimeMillis());
        BitmapFactory.Options options = new BitmapFactory.Options(); options.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(file.toString(), options);
        options.inSampleSize = 1;
        while (options.outWidth / options.inSampleSize > width * 2 || options.outHeight / options.inSampleSize > height * 2) options.inSampleSize *= 2;
        options.inJustDecodeBounds = false;
        Bitmap bitmap = BitmapFactory.decodeFile(file.toString(), options);
        if (bitmap == null) { file.delete(); throw new IOException("Unsupported image."); }
        try {
            int orientation = new ExifInterface(file.toString()).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1);
            Matrix matrix = new Matrix();
            switch (orientation) {
                case 2: matrix.setScale(-1, 1); break;
                case 3: matrix.setRotate(180); break;
                case 4: matrix.setScale(1, -1); break;
                case 5: matrix.setRotate(90); matrix.postScale(-1, 1); break;
                case 6: matrix.setRotate(90); break;
                case 7: matrix.setRotate(270); matrix.postScale(-1, 1); break;
                case 8: matrix.setRotate(270); break;
            }
            if (!matrix.isIdentity()) { Bitmap rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), matrix, true); if (rotated != bitmap) bitmap.recycle(); bitmap = rotated; }
        } catch (IOException ignored) { }
        File[] files = getCacheDir().listFiles((dir, name) -> name.endsWith(".img"));
        if (files != null) {
            Arrays.sort(files, Comparator.comparingLong(File::lastModified));
            long size = 0; for (File f : files) size += f.length();
            for (File f : files) { if (size <= MAX_CACHE) break; size -= f.length(); f.delete(); }
        }
        return bitmap;
    }
}
