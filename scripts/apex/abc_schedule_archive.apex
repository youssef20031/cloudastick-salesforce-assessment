/**
 * Schedules the order archival batch to run nightly at 02:00 org time.
 *
 *   sf apex run --file scripts/apex/abc_schedule_archive.apex --target-org abcDev
 *
 * Safe to re-run: an existing job of the same name is aborted first, so this
 * can be part of a deployment script without accumulating duplicate schedules.
 *
 * 02:00 is chosen because the job deletes Order records. Running it outside
 * business hours keeps it away from the warehouse user's working day and away
 * from the Ionic app's traffic.
 */
final String JOB_NAME = 'abc_Order_Archive_Nightly';
final String CRON_NIGHTLY_0200 = '0 0 2 * * ?';

List<CronTrigger> existing = [
    SELECT Id, CronJobDetail.Name, State, NextFireTime
    FROM CronTrigger
    WHERE CronJobDetail.Name = :JOB_NAME
];
for (CronTrigger job : existing) {
    System.abortJob(job.Id);
    System.debug(LoggingLevel.ERROR, 'Aborted the existing schedule ' + job.Id + ' so it can be replaced.');
}

Id scheduledJobId = System.schedule(JOB_NAME, CRON_NIGHTLY_0200, new abc_OrderArchiveScheduler());
System.debug(LoggingLevel.ERROR, 'Scheduled "' + JOB_NAME + '" (' + CRON_NIGHTLY_0200 + ') as ' + scheduledJobId);

for (CronTrigger job : [
    SELECT CronJobDetail.Name, CronExpression, State, NextFireTime, TimesTriggered
    FROM CronTrigger
    WHERE Id = :scheduledJobId
]) {
    System.debug(
        LoggingLevel.ERROR,
        'Confirmed: ' + job.CronJobDetail.Name + ' | ' + job.CronExpression + ' | state ' + job.State +
            ' | next fire ' + job.NextFireTime
    );
}
