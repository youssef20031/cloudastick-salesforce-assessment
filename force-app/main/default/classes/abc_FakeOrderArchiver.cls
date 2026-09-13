/**
 * Test double for abc_IOrderArchiver.
 *
 * abc_OrderArchiveBatch.execute() writes the archive row and then deletes the
 * Order. Against the real big object that is untestable: big object DML inside a
 * test is not rolled back, and mixing big object DML with sObject DML in one
 * test transaction fails. This fake takes the big object out of the picture so
 * the batch's real behaviour - mapping, ordering, deactivate-then-delete,
 * failure handling - can be asserted. The real writer has its own test,
 * abc_BigObjectOrderArchiverTest.
 *
 * All recorded state is static on purpose. Database.Stateful serialises the
 * batch instance (and therefore this fake) between chunks, so instance fields
 * would never make it back to the test's reference.
 */
@IsTest
public class abc_FakeOrderArchiver implements abc_IOrderArchiver {
    /** Every row handed to archive(), in the order it was handed over. */
    public static List<abc_Order_Archive__b> archivedRows = new List<abc_Order_Archive__b>();

    /** How many times archive() was called. */
    public static Integer callCount = 0;

    /** Largest single batch of rows handed over - used to prove bulk safety. */
    public static Integer largestBatchSize = 0;

    /** When true every row comes back as a failure. */
    public static Boolean failEverything = false;

    /** Order numbers whose rows should come back as failures. */
    public static Set<String> failOrderNumbers = new Set<String>();

    /** When true archive() throws instead of returning results. */
    public static Boolean throwOnArchive = false;

    /** When set, archive() returns this many results regardless of input size. */
    public static Integer forceResultCount = null;

    /** The error message reported on simulated failures. */
    public static final String FAILURE_MESSAGE = 'abc_FakeOrderArchiver simulated archive failure';

    /** Call this at the start of every test - statics outlive a test method. */
    public static void reset() {
        archivedRows = new List<abc_Order_Archive__b>();
        callCount = 0;
        largestBatchSize = 0;
        failEverything = false;
        failOrderNumbers = new Set<String>();
        throwOnArchive = false;
        forceResultCount = null;
    }

    /** The single recorded row. Fails the test loudly if there is not exactly one. */
    public static abc_Order_Archive__b onlyRow() {
        System.assertEquals(1, archivedRows.size(), 'Expected exactly one archived row, got ' + archivedRows.size());
        return archivedRows[0];
    }

    /** Looks up a recorded row by the order number it carries. */
    public static abc_Order_Archive__b rowFor(String orderNumber) {
        for (abc_Order_Archive__b row : archivedRows) {
            if (row.abc_Order_Number__c == orderNumber) {
                return row;
            }
        }
        return null;
    }

    public List<Database.SaveResult> archive(List<abc_Order_Archive__b> rows) {
        callCount++;
        if (throwOnArchive) {
            throw new abc_FakeArchiverException(FAILURE_MESSAGE);
        }

        Integer size = rows == null ? 0 : rows.size();
        if (size > largestBatchSize) {
            largestBatchSize = size;
        }

        List<Database.SaveResult> results = new List<Database.SaveResult>();
        if (rows != null) {
            for (abc_Order_Archive__b row : rows) {
                archivedRows.add(row);
                Boolean failed = failEverything || failOrderNumbers.contains(row.abc_Order_Number__c);
                results.add(failed ? failureResult() : successResult());
            }
        }

        if (forceResultCount != null) {
            List<Database.SaveResult> trimmed = new List<Database.SaveResult>();
            for (Integer i = 0; i < forceResultCount && i < results.size(); i++) {
                trimmed.add(results[i]);
            }
            return trimmed;
        }
        return results;
    }

    /**
     * Database.SaveResult has no public constructor, and big object rows have no
     * Id to insert against, so results are built by deserialising the shape the
     * platform itself serialises.
     */
    private static Database.SaveResult successResult() {
        return (Database.SaveResult) JSON.deserialize('{"success":true,"errors":[]}', Database.SaveResult.class);
    }

    private static Database.SaveResult failureResult() {
        return (Database.SaveResult) JSON.deserialize(
            '{"success":false,"errors":[{"message":"' +
                FAILURE_MESSAGE +
                '","statusCode":"FIELD_CUSTOM_VALIDATION_EXCEPTION","fields":[]}]}',
            Database.SaveResult.class
        );
    }

    public class abc_FakeArchiverException extends Exception {
    }
}
