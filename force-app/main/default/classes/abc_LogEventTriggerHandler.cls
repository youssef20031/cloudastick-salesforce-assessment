/**
 * Turns abc_Log_Event__e platform events into persisted abc_Log__c records.
 *
 * Declared without sharing on purpose: the subscriber runs as the Automated
 * Process user, and a log must be written regardless of who raised it or what
 * they can see. Nothing here reads business data - it only copies the payload.
 *
 * Inserts are partial-success (allOrNone = false) so one malformed entry cannot
 * suppress the rest of the batch, and failures fall back to the debug log
 * because there is nowhere else left to report them.
 */
public without sharing class abc_LogEventTriggerHandler {
    private static final String CLASS_NAME = 'abc_LogEventTriggerHandler';

    public static void handleAfterInsert(List<abc_Log_Event__e> events) {
        if (events == null || events.isEmpty()) {
            return;
        }

        List<abc_Log__c> logs = new List<abc_Log__c>();
        for (abc_Log_Event__e evt : events) {
            logs.add(
                new abc_Log__c(
                    abc_Level__c = evt.abc_Level__c,
                    abc_Source__c = evt.abc_Source__c,
                    abc_Class__c = evt.abc_Class__c,
                    abc_Method__c = evt.abc_Method__c,
                    abc_Message__c = evt.abc_Message__c,
                    abc_Stack_Trace__c = evt.abc_Stack_Trace__c,
                    abc_Record_Id__c = evt.abc_Record_Id__c,
                    abc_Request_Id__c = evt.abc_Request_Id__c,
                    abc_Quiddity__c = evt.abc_Quiddity__c,
                    abc_Http_Status__c = evt.abc_Http_Status__c,
                    abc_Logged_By__c = toUserId(evt.abc_Logged_By_Id__c),
                    // Fall back to replay time if the publisher did not stamp one.
                    abc_Timestamp__c = evt.abc_Timestamp__c == null ? System.now() : evt.abc_Timestamp__c
                )
            );
        }

        List<Database.SaveResult> results = Database.insert(logs, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(
                    LoggingLevel.ERROR,
                    CLASS_NAME + ' could not persist a log entry: ' + results[i].getErrors()
                );
            }
        }
    }

    /**
     * The event carries the user id as text, since platform events cannot hold
     * lookups. Anything that is not a well-formed User id is dropped rather than
     * failing the insert.
     */
    private static Id toUserId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            Id candidate = Id.valueOf(value);
            return candidate.getSobjectType() == User.SObjectType ? candidate : null;
        } catch (Exception e) {
            return null;
        }
    }
}
