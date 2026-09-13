/**
 * The seam between the archival batch and the big object it writes to.
 *
 * This interface exists for one concrete platform reason. Big object DML
 * (Database.insertImmediate) is treated as an immediate, out-of-transaction
 * write: inside an Apex test it is NOT rolled back, and mixing it with ordinary
 * sObject DML in the same test transaction fails outright. abc_OrderArchiveBatch
 * has to do both - write the archive row and then delete the Order - so its
 * tests could never exercise execute() against the real big object.
 *
 * Injecting the writer solves it: production runs abc_BigObjectOrderArchiver,
 * tests run abc_FakeOrderArchiver, and the real big object gets its own
 * dedicated test (abc_BigObjectOrderArchiverTest) that touches nothing else.
 *
 * Implementations must return one Database.SaveResult per input row, in the
 * same order as the input list. The batch pairs result i with row i to decide
 * which orders may be deleted.
 */
public interface abc_IOrderArchiver {
    /**
     * Writes the archive rows.
     *
     * @param rows one abc_Order_Archive__b per order being archived
     * @return one SaveResult per row, positionally aligned with rows
     */
    List<Database.SaveResult> archive(List<abc_Order_Archive__b> rows);
}
