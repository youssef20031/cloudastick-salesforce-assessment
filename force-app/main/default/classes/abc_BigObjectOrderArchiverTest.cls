/**
 * Tests for abc_BigObjectOrderArchiver, the thin adapter that writes archive
 * rows to the abc_Order_Archive__b big object.
 *
 * ---------------------------------------------------------------------------
 * Why this class tests so little, and why that is the right answer
 * ---------------------------------------------------------------------------
 * Salesforce does not support big object DML inside an Apex test.
 * Database.insertImmediate raises "System.UnexpectedException: Internal
 * Salesforce.com Query Error" from a test context - inside or outside a
 * Test.startTest/stopTest boundary - and that exception cannot be caught, so
 * the call cannot even be wrapped and tolerated. Verified against this org.
 *
 * That restriction is precisely why abc_IOrderArchiver exists. All the archival
 * behaviour worth testing - which orders qualify, how line items become JSON,
 * what happens when a write fails, and the order in which the batch archives,
 * deactivates and deletes - lives in abc_OrderArchiveBatch and is tested
 * against abc_FakeOrderArchiver in abc_OrderArchiveBatchTest.
 *
 * What is left in this adapter is one guard clause and one delegation. The
 * guard is tested below. The delegation - the single
 * `return Database.insertImmediate(rows);` statement - is deliberately left
 * uncovered, because no test may execute it. The real round trip against the
 * real big object is proved outside tests, by running
 * scripts/apex/abc_run_archive_now.apex and then
 * scripts/apex/abc_query_archive.apex, which is a documented step in the
 * deployment runbook.
 *
 * Consequence to expect: this class reports roughly 66% coverage rather than
 * the 75% the rest of the project holds. That is a platform limit, not an
 * untested code path, and it is recorded under Known Limitations in the
 * solution documentation.
 */
@IsTest
private class abc_BigObjectOrderArchiverTest {
    @IsTest
    static void archiveWithNothingToWriteDoesNotTouchTheBigObject() {
        abc_IOrderArchiver archiver = new abc_BigObjectOrderArchiver();

        List<Database.SaveResult> fromNull = archiver.archive(null);
        List<Database.SaveResult> fromEmpty = archiver.archive(new List<abc_Order_Archive__b>());

        Assert.areEqual(0, fromNull.size(), 'A null row list should be a no-op, not a DML call.');
        Assert.areEqual(0, fromEmpty.size(), 'An empty row list should be a no-op, not a DML call.');
    }

    /**
     * The batch depends on being able to hand any abc_IOrderArchiver to the
     * archiver slot. This pins the production implementation to that contract so
     * a signature change cannot silently break the injection the batch relies on.
     */
    @IsTest
    static void productionArchiverSatisfiesTheArchiverContract() {
        Object candidate = new abc_BigObjectOrderArchiver();
        Assert.isInstanceOfType(
            candidate,
            abc_IOrderArchiver.class,
            'abc_OrderArchiveBatch injects this class through the abc_IOrderArchiver interface.'
        );
    }
}
