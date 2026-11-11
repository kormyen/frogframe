package nz.kor.frogframe;

public final class UploadGroupChecks {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        UploadGroups groups = new UploadGroups();
        groups.progress("group", 0);
        for (int i = 1; i <= 102; i++) {
            groups.progress("group", i * 1000);
            check(groups.suppressChanges(i * 1000));
            check(groups.completedNotices().isEmpty());
        }
        groups.finish("group", 100, 103000); // Two duplicates were skipped.
        check(groups.suppressChanges(103000));
        check(groups.completedNotices().equals(java.util.List.of("100 images added")));
        check(!groups.suppressChanges(103000));
        groups.finish("group", 100, 104000);
        check(groups.completedNotices().isEmpty());
        groups.finish("all-duplicates", 0, 105000);
        check(groups.completedNotices().isEmpty());
        check(!groups.suppressChanges(105000));
        groups.progress("abandoned", 106000);
        check(!groups.suppressChanges(800000));
        groups.progress("one", 800000);
        groups.progress("two", 800000);
        groups.finish("one", 1, 800001);
        check(groups.completedNotices().equals(java.util.List.of("1 image added")));
        check(groups.suppressChanges(800001));
        groups.finish("two", 2, 800002);
        check(groups.completedNotices().equals(java.util.List.of("2 images added")));
        check(!groups.suppressChanges(800002));
        System.out.println("Upload group checks passed");
    }
}
