package nz.kor.frogframe;

import java.util.*;

/** Keeps navigation stable while the bucket changes. No Android dependencies. */
final class Playlist {
    static List<String> merge(List<String> previous, List<String> fresh) {
        Set<String> remaining = new LinkedHashSet<>(fresh);
        List<String> ordered = new ArrayList<>();
        for (String url : previous) if (remaining.remove(url)) ordered.add(url);
        List<String> added = new ArrayList<>(remaining);
        Collections.shuffle(added);
        ordered.addAll(added);
        return ordered;
    }

    private static String key(String url) { return url.split("\\?", 2)[0]; }

    static String notice(List<String> previous, List<String> fresh) {
        Set<String> before = new HashSet<>(), after = new HashSet<>();
        for (String url : previous) before.add(key(url));
        for (String url : fresh) after.add(key(url));
        Set<String> added = new HashSet<>(after); added.removeAll(before);
        Set<String> removed = new HashSet<>(before); removed.removeAll(after);
        List<String> parts = new ArrayList<>();
        if (!added.isEmpty()) parts.add(added.size() + (added.size() == 1 ? " image added" : " images added"));
        if (!removed.isEmpty()) parts.add(removed.size() + (removed.size() == 1 ? " image removed" : " images removed"));
        return String.join(" · ", parts);
    }
}
