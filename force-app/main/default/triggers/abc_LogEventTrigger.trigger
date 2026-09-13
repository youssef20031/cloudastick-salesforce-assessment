/**
 * Subscriber for the ABC logging framework. Deliberately a one-liner: all the
 * work lives in abc_LogEventTriggerHandler so it can be unit tested directly.
 */
trigger abc_LogEventTrigger on abc_Log_Event__e(after insert) {
    abc_LogEventTriggerHandler.handleAfterInsert(Trigger.new);
}
