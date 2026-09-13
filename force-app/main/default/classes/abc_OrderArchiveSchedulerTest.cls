/**
 * Tests for abc_OrderArchiveScheduler.
 *
 * A Schedulable is verified through the CronTrigger it produces: scheduling it
 * inside Test.startTest/stopTest makes the platform run execute() at stopTest,
 * which is what proves the class can actually launch the batch. No order data is
 * created, so the batch that starts finds nothing to archive and never reaches
 * the big object.
 */
@IsTest
private class abc_OrderArchiveSchedulerTest {
    @IsTest
    static void schedulingRegistersTheNightlyJobAndRunsTheBatch() {
        String jobName = abc_OrderArchiveScheduler.JOB_NAME + '_Test';

        Test.startTest();
        String jobId = System.schedule(jobName, abc_OrderArchiveScheduler.CRON_NIGHTLY_2AM, new abc_OrderArchiveScheduler());
        Test.stopTest();

        List<CronTrigger> triggers = [
            SELECT Id, CronExpression, TimesTriggered, NextFireTime, State, CronJobDetail.Name
            FROM CronTrigger
            WHERE Id = :jobId
        ];

        System.assertEquals(1, triggers.size(), 'Scheduling should create exactly one CronTrigger.');
        System.assertEquals(
            abc_OrderArchiveScheduler.CRON_NIGHTLY_2AM,
            triggers[0].CronExpression,
            'The job should be registered with the nightly 02:00 cron expression.'
        );
        System.assertEquals(jobName, triggers[0].CronJobDetail.Name, 'The job should carry the agreed name.');
    }

    @IsTest
    static void cronExpressionIsDailyAtTwoInTheMorning() {
        // Seconds, minutes, hours, day-of-month, month, day-of-week.
        List<String> parts = abc_OrderArchiveScheduler.CRON_NIGHTLY_2AM.split(' ');

        System.assertEquals(6, parts.size(), 'A Salesforce cron expression has six fields.');
        System.assertEquals('0', parts[0], 'Seconds should be 0.');
        System.assertEquals('0', parts[1], 'Minutes should be 0.');
        System.assertEquals('2', parts[2], 'Hours should be 2, i.e. 02:00.');
        System.assertEquals('*', parts[3], 'Every day of the month.');
        System.assertEquals('*', parts[4], 'Every month.');
        System.assertEquals('?', parts[5], 'Day-of-week unspecified, as required when day-of-month is set.');
        System.assertEquals(
            'abc_Order_Archive_Nightly',
            abc_OrderArchiveScheduler.JOB_NAME,
            'scripts/apex/abc_schedule_archive.apex aborts and recreates the job by this exact name.'
        );
    }
}
