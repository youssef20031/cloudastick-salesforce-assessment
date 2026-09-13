/**
 * Turns an incoming REST request into the part of the path a resource routes on.
 *
 * Apex REST gives one class a single @HttpPost and a single @HttpGet, so a
 * resource that serves several paths under one prefix - as the cart resource
 * does, with create, read, add-item and checkout - has to dispatch on the path
 * itself. This class is the one place that knows how to get that path out of a
 * RestRequest, so the resources stay readable and the parsing is tested once.
 *
 * requestURI is not consistent across callers: depending on how the request was
 * made it may or may not carry the "/services/apexrest" prefix, may or may not
 * have a trailing slash, and may carry a query string. All three are normalised
 * away here.
 */
public with sharing class abc_RestRouter {
    private static final String APEXREST_PREFIX = '/services/apexrest';

    private abc_RestRouter() {
        // Static utility - never instantiated.
    }

    /**
     * The path remaining after the resource's own base path.
     *
     * For base "/abc/v1/carts":
     *   /services/apexrest/abc/v1/carts            -> ''
     *   /abc/v1/carts/                             -> ''
     *   /abc/v1/carts/801xx0000000001              -> '801xx0000000001'
     *   /abc/v1/carts/801xx0000000001/items        -> '801xx0000000001/items'
     *   /abc/v1/carts/801xx0000000001/checkout?x=1 -> '801xx0000000001/checkout'
     *
     * @return the remainder with no leading or trailing slash, never null
     */
    public static String suffix(RestRequest request, String basePath) {
        if (request == null || String.isBlank(request.requestURI)) {
            return '';
        }

        String path = request.requestURI;

        Integer queryAt = path.indexOf('?');
        if (queryAt >= 0) {
            path = path.substring(0, queryAt);
        }
        if (path.startsWith(APEXREST_PREFIX)) {
            path = path.substring(APEXREST_PREFIX.length());
        }

        Integer baseAt = path.indexOf(basePath);
        if (baseAt >= 0) {
            path = path.substring(baseAt + basePath.length());
        }

        return trimSlashes(path);
    }

    /** The suffix split on '/', with empty segments dropped. */
    public static List<String> segments(RestRequest request, String basePath) {
        List<String> parts = new List<String>();
        for (String part : suffix(request, basePath).split('/')) {
            if (String.isNotBlank(part)) {
                parts.add(part);
            }
        }
        return parts;
    }

    /**
     * A query parameter, or null when it was absent or blank. Apex populates
     * params for GET requests; a missing map is treated as no parameters.
     */
    public static String param(RestRequest request, String name) {
        if (request == null || request.params == null) {
            return null;
        }
        String value = request.params.get(name);
        return String.isBlank(value) ? null : value.trim();
    }

    /**
     * A query parameter read as an Integer.
     *
     * @throws abc_ApiException INVALID_INPUT when present but not a whole number
     */
    public static Integer intParam(RestRequest request, String name) {
        String raw = param(request, name);
        if (raw == null) {
            return null;
        }
        try {
            return Integer.valueOf(raw);
        } catch (Exception e) {
            throw abc_ApiException.invalidInput(name + ' must be a whole number, received "' + raw + '".', name);
        }
    }

    /**
     * A query parameter read as a Boolean. Only "true" and "false" are accepted;
     * anything else is a client bug and is reported rather than guessed at.
     *
     * @throws abc_ApiException INVALID_INPUT when present but not true or false
     */
    public static Boolean boolParam(RestRequest request, String name) {
        String raw = param(request, name);
        if (raw == null) {
            return null;
        }
        String lowered = raw.toLowerCase();
        if (lowered == 'true') {
            return true;
        }
        if (lowered == 'false') {
            return false;
        }
        throw abc_ApiException.invalidInput(name + ' must be true or false, received "' + raw + '".', name);
    }

    /** The request body as text, or null when there is no body. */
    public static String body(RestRequest request) {
        if (request == null || request.requestBody == null) {
            return null;
        }
        String raw = request.requestBody.toString();
        return String.isBlank(raw) ? null : raw;
    }

    private static String trimSlashes(String value) {
        String result = value == null ? '' : value;
        while (result.startsWith('/')) {
            result = result.substring(1);
        }
        while (result.endsWith('/')) {
            result = result.substring(0, result.length() - 1);
        }
        return result;
    }
}
