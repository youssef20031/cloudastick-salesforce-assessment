/**
 * Nightly trigger for abc_OrderArchiveBatch.
 *
 * Scheduled at 02:00 every day with the cron expression "0 0 2 * * ?" under the
 * job name abc_Order_Archive_Nightly. 02:00 keeps the archival window clear of
 * both the business day and the Ionic app's traffic, and running daily means any
 * order crosses the one-year line at most 24 hours after it qualifies.
 *
 * Install or reinstall it with:
 *   sf apex run --file scripts/apex/abc_schedule_archive.apex --target-org abcDev
 */
public with sharing class abc_OrderArchiveScheduler implements Schedulable {
    /** The single scheduled job name this class is installed under. */
    public static final String JOB_NAME = 'abc_Order_Archive_Nightly';

    /** Daily at 02:00 - seconds, minutes, hours, day-of-month, month, day-of-week. */
    public static final String CRON_NIGHTLY_2AM = '0 0 2 * * ?';

    public void execute(SchedulableContext context) {
        Database.executeBatch(new abc_OrderArchiveBatch(), abc_OrderArchiveBatch.SCOPE_SIZE);
    }
}
