package nz.kor.frogframe;

import java.util.*;

public class PlaylistChecks {
    public static void main(String[] args) {
        check(Playlist.merge(Arrays.asList("c", "a", "b"), Arrays.asList("a", "c")).equals(Arrays.asList("c", "a")), "Delete preserves navigation order");
        List<String> merged = Playlist.merge(Arrays.asList("c", "a"), Arrays.asList("a", "b", "c", "d"));
        check(merged.subList(0, 2).equals(Arrays.asList("c", "a")), "Add preserves existing order");
        check(new HashSet<>(merged).equals(new HashSet<>(Arrays.asList("a", "b", "c", "d"))), "Add includes all new images");
        check(Playlist.merge(Arrays.asList("a"), Collections.emptyList()).isEmpty(), "Delete last image");
        check(Playlist.notice(Collections.emptyList(), Arrays.asList("a", "b", "c", "d", "e", "f", "g", "h", "i")).equals("9 images added"), "Plural added toast");
        check(Playlist.notice(Arrays.asList("a", "b"), Arrays.asList("b")).equals("1 image removed"), "Singular removed toast");
        check(Playlist.notice(Arrays.asList("a", "b"), Arrays.asList("b", "c")).equals("1 image added · 1 image removed"), "Mixed toast");
        check(Playlist.notice(Arrays.asList("https://photos/image/a?v=1"), Arrays.asList("https://photos/image/a?v=2")).isEmpty(), "Replacement is not an added image");
        check(Playlist.notice(Arrays.asList("a", "b"), Arrays.asList("b", "a")).isEmpty(), "Reordering has no toast");
        System.out.println("9 playlist and toast checks passed");
    }
    private static void check(boolean value, String name) { if (!value) throw new AssertionError(name); }
}
