/**
 * Tests for the ABC logging framework: abc_Logger, abc_LogEventTrigger and
 * abc_LogEventTriggerHandler.
 *
 * Platform events are only delivered at a transaction boundary, so each test
 * that expects abc_Log__c rows publishes inside Test.startTest/stopTest or calls
 * Test.getEventBus().deliver() explicitly.
 */
@IsTest
private class abc_LoggerTest {
    @IsTest
    static void flushPersistsOneLogRecordPerBufferedEntry() {
        abc_Logger.setSource(abc_Logger.SOURCE_REST);
        abc_Logger.info('abc_SomeClass', 'someMethod', 'first');
        abc_Logger.warn('abc_SomeClass', 'someMethod', 'second');

        System.assertEquals(2, abc_Logger.bufferedCount(), 'Entries should be buffered, not published yet.');
        System.assertEquals(0, [SELECT COUNT() FROM abc_Log__c], 'Nothing should be persisted before flush.');

        Test.startTest();
        abc_Logger.flush();
        Test.stopTest();

        List<abc_Log__c> logs = [
            SELECT abc_Level__c, abc_Source__c, abc_Class__c, abc_Method__c, abc_Message__c, abc_Logged_By__c,
                abc_Request_Id__c, abc_Timestamp__c
            FROM abc_Log__c
            ORDER BY abc_Level__c
        ];
        System.assertEquals(2, logs.size(), 'Both buffered entries should be persisted.');

        // Ordered by level: INFO then WARN.
        System.assertEquals(abc_Logger.LEVEL_INFO, logs[0].abc_Level__c);
        System.assertEquals('first', logs[0].abc_Message__c);
        System.assertEquals(abc_Logger.LEVEL_WARN, logs[1].abc_Level__c);
        System.assertEquals('second', logs[1].abc_Message__c);

        for (abc_Log__c log : logs) {
            System.assertEquals(abc_Logger.SOURCE_REST, log.abc_Source__c, 'Source should be carried through.');
            System.assertEquals('abc_SomeClass', log.abc_Class__c);
            System.assertEquals('someMethod', log.abc_Method__c);
            System.assertEquals(UserInfo.getUserId(), log.abc_Logged_By__c, 'Running user should be resolved.');
            System.assertNotEquals(null, log.abc_Timestamp__c, 'Timestamp should be stamped in Apex.');
        }
    }

    @IsTest
    static void flushEmptiesTheBufferSoASecondFlushIsANoOp() {
        abc_Logger.info('abc_SomeClass', 'someMethod', 'only once');

        Test.startTest();
        abc_Logger.flush();
        abc_Logger.flush();
        Test.stopTest();

        System.assertEquals(0, abc_Logger.bufferedCount(), 'Buffer should be empty after flushing.');
        System.assertEquals(1, [SELECT COUNT() FROM abc_Log__c], 'The entry should be persisted exactly once.');
    }

    @IsTest
    static void flushWithNothingBufferedPublishesNothing() {
        Test.startTest();
        abc_Logger.flush();
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM abc_Log__c], 'An empty flush should be harmless.');
    }

    @IsTest
    static void errorWithExceptionCapturesTypeAndStackTrace() {
        Test.startTest();
        try {
            String value = null;
            value.length();
            System.assert(false, 'Expected a null pointer exception.');
        } catch (Exception e) {
            abc_Logger.error('abc_SomeClass', 'boom', 'Something failed', e, null, 500);
        }
        abc_Logger.flush();
        Test.stopTest();

        abc_Log__c log = [
            SELECT abc_Level__c, abc_Message__c, abc_Stack_Trace__c, abc_Http_Status__c, abc_Quiddity__c
            FROM abc_Log__c
            LIMIT 1
        ];
        System.assertEquals(abc_Logger.LEVEL_ERROR, log.abc_Level__c);
        System.assert(log.abc_Message__c.contains('Something failed'), 'The caller message should be kept.');
        System.assert(
            log.abc_Message__c.contains('NullPointerException'),
            'The exception type should be appended: ' + log.abc_Message__c
        );
        System.assertNotEquals(null, log.abc_Stack_Trace__c, 'A stack trace should be captured.');
        System.assertEquals(500, log.abc_Http_Status__c, 'The HTTP status should be recorded.');
        System.assertNotEquals(null, log.abc_Quiddity__c, 'The execution context should be recorded.');
    }

    @IsTest
    static void recordIdIsRecordedWhenSupplied() {
        Account account = abc_TestDataFactory.createCustomer('Nadia', 'Farouk', 'nadia.farouk@example.com');

        Test.startTest();
        abc_Logger.warn('abc_SomeClass', 'someMethod', 'Related to a record', account.Id);
        abc_Logger.flush();
        Test.stopTest();

        abc_Log__c log = [SELECT abc_Record_Id__c FROM abc_Log__c LIMIT 1];
        System.assertEquals(account.Id, log.abc_Record_Id__c, 'The related record id should be stored.');
    }

    @IsTest
    static void longMessagesAreTruncatedRatherThanLost() {
        String huge = 'x'.repeat(40000);

        Test.startTest();
        abc_Logger.info('abc_SomeClass', 'someMethod', huge);
        abc_Logger.flush();
        Test.stopTest();

        abc_Log__c log = [SELECT abc_Message__c FROM abc_Log__c LIMIT 1];
        System.assertEquals(32768, log.abc_Message__c.length(), 'The message should be truncated to the field size.');
    }

    @IsTest
    static void bufferIsCappedSoARunawayLoopCannotBreachPublishingLimits() {
        for (Integer i = 0; i < 300; i++) {
            abc_Logger.debug('abc_SomeClass', 'loop', 'entry ' + i);
        }
        System.assertEquals(250, abc_Logger.bufferedCount(), 'The buffer should stop growing at the cap.');

        Test.startTest();
        abc_Logger.flush();
        Test.stopTest();

        System.assertEquals(250, [SELECT COUNT() FROM abc_Log__c], 'Only the capped entries should be persisted.');
    }

    @IsTest
    static void discardDropsBufferedEntriesWithoutPublishing() {
        abc_Logger.info('abc_SomeClass', 'someMethod', 'never published');
        abc_Logger.discard();

        Test.startTest();
        abc_Logger.flush();
        Test.stopTest();

        System.assertEquals(0, abc_Logger.bufferedCount());
        System.assertEquals(0, [SELECT COUNT() FROM abc_Log__c], 'Discarded entries should not reach the database.');
    }

    @IsTest
    static void setSourceFallsBackToOtherWhenBlank() {
        abc_Logger.setSource('   ');

        Test.startTest();
        abc_Logger.info('abc_SomeClass', 'someMethod', 'no source given');
        abc_Logger.flush();
        Test.stopTest();

        abc_Log__c log = [SELECT abc_Source__c FROM abc_Log__c LIMIT 1];
        System.assertEquals(abc_Logger.SOURCE_OTHER, log.abc_Source__c);
    }

    @IsTest
    static void getRequestIdIsStableWithinATransaction() {
        String first = abc_Logger.getRequestId();
        String second = abc_Logger.getRequestId();
        System.assertNotEquals(null, first, 'A request id should be available.');
        System.assertEquals(first, second, 'The correlation id must not change mid-transaction.');
    }

    @IsTest
    static void handlerIgnoresAnUnusableLoggedByIdInsteadOfFailingTheInsert() {
        List<abc_Log_Event__e> events = new List<abc_Log_Event__e>{
            new abc_Log_Event__e(
                abc_Level__c = abc_Logger.LEVEL_INFO,
                abc_Message__c = 'blank user',
                abc_Logged_By_Id__c = null
            ),
            new abc_Log_Event__e(
                abc_Level__c = abc_Logger.LEVEL_INFO,
                abc_Message__c = 'malformed user',
                abc_Logged_By_Id__c = 'not-an-id'
            ),
            new abc_Log_Event__e(
                abc_Level__c = abc_Logger.LEVEL_INFO,
                abc_Message__c = 'wrong sobject',
                abc_Logged_By_Id__c = UserInfo.getOrganizationId()
            )
        };

        Test.startTest();
        abc_LogEventTriggerHandler.handleAfterInsert(events);
        Test.stopTest();

        List<abc_Log__c> logs = [SELECT abc_Logged_By__c, abc_Timestamp__c FROM abc_Log__c];
        System.assertEquals(3, logs.size(), 'All three entries should still be persisted.');
        for (abc_Log__c log : logs) {
            System.assertEquals(null, log.abc_Logged_By__c, 'An unusable id should be dropped, not fatal.');
            System.assertNotEquals(null, log.abc_Timestamp__c, 'A missing timestamp should fall back to now.');
        }
    }

    @IsTest
    static void handlerToleratesAnEmptyEventList() {
        Test.startTest();
        abc_LogEventTriggerHandler.handleAfterInsert(new List<abc_Log_Event__e>());
        abc_LogEventTriggerHandler.handleAfterInsert(null);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM abc_Log__c]);
    }
}
