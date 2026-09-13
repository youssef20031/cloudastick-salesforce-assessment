/**
 * Rollback-safe application logger for the ABC pharmacy solution.
 *
 * Business code never inserts abc_Log__c directly. It buffers abc_Log_Event__e
 * platform events here and calls flush() once, normally from a finally block.
 * The event is declared PublishImmediately, so entries survive a transaction
 * that later rolls back - which is exactly the transaction whose log you need.
 *
 * Every entry carries the request id from Request.getCurrent(). The REST layer
 * returns that same id to the caller, so a requestId quoted in a support ticket
 * leads straight to the rows that explain it.
 *
 * Usage:
 *   try {
 *       ...
 *   } catch (Exception e) {
 *       abc_Logger.error(CLASS_NAME, 'doWork', 'Could not do work', e);
 *       throw e;
 *   } finally {
 *       abc_Logger.flush();
 *   }
 */
public with sharing class abc_Logger {
    public static final String LEVEL_DEBUG = 'DEBUG';
    public static final String LEVEL_INFO = 'INFO';
    public static final String LEVEL_WARN = 'WARN';
    public static final String LEVEL_ERROR = 'ERROR';

    public static final String SOURCE_REST = 'REST';
    public static final String SOURCE_BATCH = 'Batch';
    public static final String SOURCE_TRIGGER = 'Trigger';
    public static final String SOURCE_VISUALFORCE = 'Visualforce';
    public static final String SOURCE_OTHER = 'Other';

    /** Field lengths on abc_Log_Event__e. Entries are truncated rather than lost. */
    private static final Integer MAX_LONG_TEXT = 32768;
    private static final Integer MAX_CLASS = 255;
    private static final Integer MAX_METHOD = 255;
    private static final Integer MAX_QUIDDITY = 40;

    /**
     * Upper bound on buffered entries. A runaway loop should not turn one failed
     * transaction into a platform-event publishing limit breach; past this point
     * entries fall back to the debug log only.
     */
    private static final Integer MAX_BUFFERED = 250;

    @TestVisible
    private static List<abc_Log_Event__e> buffer = new List<abc_Log_Event__e>();

    private static String currentSource = SOURCE_OTHER;
    private static Integer dropped = 0;

    private abc_Logger() {
        // Static utility - never instantiated.
    }

    /**
     * Tags every subsequent entry in this transaction with its originating
     * subsystem, so REST noise can be filtered away from batch or trigger work.
     */
    public static void setSource(String source) {
        currentSource = String.isBlank(source) ? SOURCE_OTHER : source;
    }

    /** Correlation id for this execution, also returned in every API response. */
    public static String getRequestId() {
        try {
            return Request.getCurrent().getRequestId();
        } catch (Exception e) {
            // Request context is unavailable in a small number of exotic contexts.
            return null;
        }
    }

    public static void debug(String className, String methodName, String message) {
        add(LEVEL_DEBUG, className, methodName, message, null, null, null);
    }

    public static void info(String className, String methodName, String message) {
        add(LEVEL_INFO, className, methodName, message, null, null, null);
    }

    public static void warn(String className, String methodName, String message) {
        add(LEVEL_WARN, className, methodName, message, null, null, null);
    }

    public static void warn(String className, String methodName, String message, Id recordId) {
        add(LEVEL_WARN, className, methodName, message, null, recordId, null);
    }

    public static void error(String className, String methodName, String message) {
        add(LEVEL_ERROR, className, methodName, message, null, null, null);
    }

    public static void error(String className, String methodName, String message, Exception ex) {
        add(LEVEL_ERROR, className, methodName, message, ex, null, null);
    }

    public static void error(String className, String methodName, String message, Exception ex, Id recordId) {
        add(LEVEL_ERROR, className, methodName, message, ex, recordId, null);
    }

    public static void error(
        String className,
        String methodName,
        String message,
        Exception ex,
        Id recordId,
        Integer httpStatus
    ) {
        add(LEVEL_ERROR, className, methodName, message, ex, recordId, httpStatus);
    }

    private static void add(
        String level,
        String className,
        String methodName,
        String message,
        Exception ex,
        Id recordId,
        Integer httpStatus
    ) {
        if (buffer.size() >= MAX_BUFFERED) {
            dropped++;
            System.debug(LoggingLevel.WARN, 'abc_Logger buffer full, dropped: ' + level + ' ' + message);
            return;
        }

        String fullMessage = message;
        String stack = null;
        if (ex != null) {
            fullMessage = String.isBlank(message) ? ex.getMessage() : message + ' | ' + ex.getMessage();
            fullMessage += ' [' + ex.getTypeName() + ']';
            stack = ex.getStackTraceString();
            if (ex.getCause() != null) {
                stack += '\nCaused by: ' + ex.getCause().getTypeName() + ': ' + ex.getCause().getMessage();
            }
        }

        buffer.add(
            new abc_Log_Event__e(
                abc_Level__c = level,
                abc_Source__c = currentSource,
                abc_Class__c = truncate(className, MAX_CLASS),
                abc_Method__c = truncate(methodName, MAX_METHOD),
                abc_Message__c = truncate(fullMessage, MAX_LONG_TEXT),
                abc_Stack_Trace__c = truncate(stack, MAX_LONG_TEXT),
                abc_Record_Id__c = recordId,
                abc_Request_Id__c = getRequestId(),
                abc_Quiddity__c = truncate(getQuiddity(), MAX_QUIDDITY),
                abc_Logged_By_Id__c = UserInfo.getUserId(),
                abc_Timestamp__c = System.now(),
                abc_Http_Status__c = httpStatus
            )
        );
    }

    /**
     * Publishes everything buffered so far and empties the buffer. Safe to call
     * more than once and safe to call when nothing has been logged, so it can
     * sit unconditionally in a finally block.
     *
     * Never throws: a logging failure must not become the error the caller sees.
     */
    public static void flush() {
        if (buffer.isEmpty()) {
            return;
        }
        List<abc_Log_Event__e> toPublish = buffer;
        buffer = new List<abc_Log_Event__e>();

        if (dropped > 0) {
            System.debug(LoggingLevel.WARN, 'abc_Logger dropped ' + dropped + ' entries over the buffer cap.');
            dropped = 0;
        }

        try {
            List<Database.SaveResult> results = EventBus.publish(toPublish);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    // Nowhere left to log to - the debug log is the last resort.
                    System.debug(
                        LoggingLevel.ERROR,
                        'abc_Logger could not publish entry ' + i + ': ' + results[i].getErrors()
                    );
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'abc_Logger.flush failed: ' + e.getMessage());
        }
    }

    /** Number of entries waiting to be published. Used by tests. */
    @TestVisible
    private static Integer bufferedCount() {
        return buffer.size();
    }

    /** Discards anything buffered without publishing it. Used by tests. */
    @TestVisible
    private static void discard() {
        buffer = new List<abc_Log_Event__e>();
        dropped = 0;
        currentSource = SOURCE_OTHER;
    }

    private static String getQuiddity() {
        try {
            return String.valueOf(Request.getCurrent().getQuiddity());
        } catch (Exception e) {
            return null;
        }
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null) {
            return null;
        }
        return value.length() <= maxLength ? value : value.substring(0, maxLength);
    }
}
