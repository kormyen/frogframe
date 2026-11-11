package nz.kor.frogframe;

import java.util.*;

/** Collects one completion notice per upload group while lists can still refresh. */
final class UploadGroups {
    private final Map<String, Long> active = new HashMap<>();
    private final Map<String, Integer> finished = new LinkedHashMap<>();
    private final Set<String> announced = new LinkedHashSet<>();
    private static final long TIMEOUT_MS = 10 * 60 * 1000;

    void progress(String group, long now) {
        if (!group.isEmpty() && !announced.contains(group)) active.put(group, now);
    }

    void finish(String group, int added, long now) {
        if (group.isEmpty() || added < 0 || announced.contains(group)) return;
        progress(group, now);
        finished.put(group, added);
    }

    boolean suppressChanges(long now) {
        // Release abandoned groups if the Mac closes before it sends completion.
        active.entrySet().removeIf(entry -> now - entry.getValue() > TIMEOUT_MS && !finished.containsKey(entry.getKey()));
        return !active.isEmpty();
    }

    List<String> completedNotices() {
        List<String> notices = new ArrayList<>();
        for (Map.Entry<String, Integer> group : finished.entrySet()) {
            int count = group.getValue();
            if (count > 0) notices.add(count + (count == 1 ? " image added" : " images added"));
            active.remove(group.getKey());
            announced.add(group.getKey());
        }
        finished.clear();
        while (announced.size() > 100) announced.remove(announced.iterator().next());
        return notices;
    }
}
