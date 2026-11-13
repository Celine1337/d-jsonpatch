// d-jsonpatch - apply RFC 6902 JSON Patch documents. Pure D (Phobos only).
//
//   d-jsonpatch <doc.json> <patch.json>
//
// Reads a JSON document and a JSON Patch (an array of operations), applies the
// operations in order, and prints the resulting JSON. All six RFC 6902 ops are
// supported: add, remove, replace, move, copy and test. Paths are JSON Pointers
// (RFC 6901): "" is the root, "/a/b/0" walks object keys and array indices,
// "~1" decodes to "/" and "~0" to "~", and "-" appends to an array.
//
// Output is compact and deterministic: object keys are emitted in sorted order
// so the same input always produces byte-identical output.
//
// Exit codes:
//   0  patch applied successfully
//   1  a test op failed, a path was invalid, or the JSON/patch was malformed
//      (an error is printed to stderr and NO result is printed)
//   2  bad usage or a missing/unreadable file
import std.json;
import std.stdio;
import std.file;
import std.conv;
import std.string;
import std.algorithm;
import std.array;
import std.format;

// A patch-level failure: invalid path, failed test, malformed operation, etc.
class PatchError : Exception {
    this(string msg) { super(msg); }
}

// Deep-copy a JSONValue so move/copy never alias the source structure.
JSONValue deepCopy(JSONValue v) {
    final switch (v.type) {
        case JSONType.object:
            JSONValue[string] o;
            foreach (k, val; v.object) o[k] = deepCopy(val);
            return JSONValue(o);
        case JSONType.array:
            JSONValue[] a;
            a.reserve(v.array.length);
            foreach (val; v.array) a ~= deepCopy(val);
            return JSONValue(a);
        case JSONType.null_, JSONType.string, JSONType.integer,
             JSONType.uinteger, JSONType.float_, JSONType.true_, JSONType.false_:
            return v;
    }
}

// Split a JSON Pointer into decoded reference tokens. "" -> no tokens (root).
string[] pointerTokens(string ptr) {
    if (ptr.empty) return [];
    if (ptr[0] != '/')
        throw new PatchError("invalid JSON pointer: \"" ~ ptr ~ "\" (must start with '/')");
    string[] toks = ptr.split("/")[1 .. $];
    foreach (ref t; toks)
        t = t.replace("~1", "/").replace("~0", "~");
    return toks;
}

// Validate an array index token. For `add`, idx == len (append) is allowed and
// "-" means append; for other ops the index must already exist.
size_t arrayIndex(string tok, size_t len, bool forAdd, string ptr) {
    if (tok == "-") {
        if (forAdd) return len;
        throw new PatchError("invalid array index \"-\" in \"" ~ ptr ~ "\"");
    }
    if (tok.empty || !tok.all!(c => c >= '0' && c <= '9')())
        throw new PatchError("invalid array index \"" ~ tok ~ "\" in \"" ~ ptr ~ "\"");
    if (tok.length > 1 && tok[0] == '0')
        throw new PatchError("invalid array index \"" ~ tok ~ "\" (leading zero)");
    size_t idx;
    try { idx = tok.to!size_t; }
    catch (ConvException e) { throw new PatchError("array index out of range: \"" ~ tok ~ "\""); }
    if (forAdd ? idx > len : idx >= len)
        throw new PatchError("array index out of bounds: \"" ~ tok ~ "\"");
    return idx;
}

// Walk tokens from the root, returning a reference to the addressed value.
// Throws PatchError if any step is missing or descends into a scalar.
ref JSONValue navigate(ref JSONValue root, string[] toks, string ptr) {
    JSONValue* cur = &root;
    foreach (t; toks) {
        if (cur.type == JSONType.object) {
            auto p = t in cur.object;
            if (p is null)
                throw new PatchError("path not found: \"" ~ ptr ~ "\" (no key \"" ~ t ~ "\")");
            cur = p;
        } else if (cur.type == JSONType.array) {
            size_t idx = arrayIndex(t, cur.array.length, false, ptr);
            cur = &cur.array[idx];
        } else {
            throw new PatchError("path not found: \"" ~ ptr ~ "\" (cannot descend into a scalar)");
        }
    }
    return *cur;
}

JSONValue requireMember(JSONValue op, string key) {
    if (op.type != JSONType.object)
        throw new PatchError("patch operation must be an object");
    auto p = key in op.object;
    if (p is null)
        throw new PatchError("patch operation missing \"" ~ key ~ "\"");
    return *p;
}

string requireString(JSONValue op, string key) {
    JSONValue v = requireMember(op, key);
    if (v.type != JSONType.string)
        throw new PatchError("\"" ~ key ~ "\" must be a string");
    return v.str;
}

void opAdd(ref JSONValue doc, string[] toks, string ptr, JSONValue value) {
    if (toks.empty) { doc = deepCopy(value); return; }
    string last = toks[$ - 1];
    ref JSONValue parent = navigate(doc, toks[0 .. $ - 1], ptr);
    if (parent.type == JSONType.object) {
        parent.object[last] = deepCopy(value);
    } else if (parent.type == JSONType.array) {
        size_t idx = arrayIndex(last, parent.array.length, true, ptr);
        if (idx == parent.array.length)
            parent.array ~= deepCopy(value);
        else
            parent.array = parent.array[0 .. idx] ~ [deepCopy(value)] ~ parent.array[idx .. $];
    } else {
        throw new PatchError("cannot add under a scalar at \"" ~ ptr ~ "\"");
    }
}

void opRemove(ref JSONValue doc, string[] toks, string ptr) {
    if (toks.empty)
        throw new PatchError("cannot remove the root document");
    string last = toks[$ - 1];
    ref JSONValue parent = navigate(doc, toks[0 .. $ - 1], ptr);
    if (parent.type == JSONType.object) {
        if ((last in parent.object) is null)
            throw new PatchError("path not found: \"" ~ ptr ~ "\"");
        parent.object.remove(last);
    } else if (parent.type == JSONType.array) {
        size_t idx = arrayIndex(last, parent.array.length, false, ptr);
        parent.array = parent.array[0 .. idx] ~ parent.array[idx + 1 .. $];
    } else {
        throw new PatchError("cannot remove under a scalar at \"" ~ ptr ~ "\"");
    }
}

void opReplace(ref JSONValue doc, string[] toks, string ptr, JSONValue value) {
    if (toks.empty) { doc = deepCopy(value); return; }
    ref JSONValue target = navigate(doc, toks, ptr);
    target = deepCopy(value);
}

void opMove(ref JSONValue doc, JSONValue op) {
    string fromPtr = requireString(op, "from");
    string pathPtr = requireString(op, "path");
    string[] fromToks = pointerTokens(fromPtr);
    string[] pathToks = pointerTokens(pathPtr);
    if (pathToks.length > fromToks.length && pathToks[0 .. fromToks.length] == fromToks)
        throw new PatchError("cannot move \"" ~ fromPtr ~ "\" into its own child \"" ~ pathPtr ~ "\"");
    JSONValue value = deepCopy(navigate(doc, fromToks, fromPtr));
    opRemove(doc, fromToks, fromPtr);
    opAdd(doc, pathToks, pathPtr, value);
}

void opCopy(ref JSONValue doc, JSONValue op) {
    string fromPtr = requireString(op, "from");
    string pathPtr = requireString(op, "path");
    JSONValue value = deepCopy(navigate(doc, pointerTokens(fromPtr), fromPtr));
    opAdd(doc, pointerTokens(pathPtr), pathPtr, value);
}

void opTest(ref JSONValue doc, string[] toks, string ptr, JSONValue expected) {
    ref JSONValue actual = navigate(doc, toks, ptr);
    if (actual != expected)
        throw new PatchError("test failed at \"" ~ ptr ~ "\"");
}

void applyOp(ref JSONValue doc, JSONValue op) {
    string kind = requireString(op, "op");
    string ptr = requireString(op, "path");
    string[] toks = pointerTokens(ptr);
    switch (kind) {
        case "add":     opAdd(doc, toks, ptr, requireMember(op, "value")); break;
        case "remove":  opRemove(doc, toks, ptr); break;
        case "replace": opReplace(doc, toks, ptr, requireMember(op, "value")); break;
        case "move":    opMove(doc, op); break;
        case "copy":    opCopy(doc, op); break;
        case "test":    opTest(doc, toks, ptr, requireMember(op, "value")); break;
        default: throw new PatchError("unknown op \"" ~ kind ~ "\"");
    }
}

// Emit a JSON string literal with the required escapes.
void writeJsonString(string s, ref Appender!string out_) {
    out_.put('"');
    foreach (char c; s) {
        switch (c) {
            case '"':  out_.put("\\\""); break;
            case '\\': out_.put("\\\\"); break;
            case '\n': out_.put("\\n"); break;
            case '\r': out_.put("\\r"); break;
            case '\t': out_.put("\\t"); break;
            case '\b': out_.put("\\b"); break;
            case '\f': out_.put("\\f"); break;
            default:
                if (c < 0x20) out_.put(format("\\u%04x", cast(uint) c));
                else out_.put(c);
        }
    }
    out_.put('"');
}

// Compact, deterministic serialization: object keys are sorted so output does
// not depend on hash-table iteration order.
void serialize(JSONValue v, ref Appender!string out_) {
    final switch (v.type) {
        case JSONType.null_:    out_.put("null"); break;
        case JSONType.true_:    out_.put("true"); break;
        case JSONType.false_:   out_.put("false"); break;
        case JSONType.string:   writeJsonString(v.str, out_); break;
        case JSONType.integer:  out_.put(v.integer.to!string); break;
        case JSONType.uinteger: out_.put(v.uinteger.to!string); break;
        case JSONType.float_:   out_.put(v.floating.to!string); break;
        case JSONType.array:
            out_.put('[');
            foreach (i, el; v.array) {
                if (i) out_.put(',');
                serialize(el, out_);
            }
            out_.put(']');
            break;
        case JSONType.object:
            out_.put('{');
            auto keys = v.object.keys;
            keys.sort();
            foreach (i, k; keys) {
                if (i) out_.put(',');
                writeJsonString(k, out_);
                out_.put(':');
                serialize(v.object[k], out_);
            }
            out_.put('}');
            break;
    }
}

int main(string[] args) {
    if (args.length != 3) {
        stderr.writeln("usage: d-jsonpatch <doc.json> <patch.json>");
        return 2;
    }
    string docText, patchText;
    try { docText = readText(args[1]); }
    catch (Exception e) {
        stderr.writeln("d-jsonpatch: cannot read ", args[1], ": ", e.msg);
        return 2;
    }
    try { patchText = readText(args[2]); }
    catch (Exception e) {
        stderr.writeln("d-jsonpatch: cannot read ", args[2], ": ", e.msg);
        return 2;
    }
    JSONValue doc, patch;
    try { doc = parseJSON(docText); }
    catch (JSONException e) {
        stderr.writeln("d-jsonpatch: invalid JSON in ", args[1], ": ", e.msg);
        return 1;
    }
    try { patch = parseJSON(patchText); }
    catch (JSONException e) {
        stderr.writeln("d-jsonpatch: invalid JSON in ", args[2], ": ", e.msg);
        return 1;
    }
    if (patch.type != JSONType.array) {
        stderr.writeln("d-jsonpatch: patch must be a JSON array of operations");
        return 1;
    }
    try {
        foreach (op; patch.array) applyOp(doc, op);
    } catch (PatchError e) {
        stderr.writeln("d-jsonpatch: ", e.msg);
        return 1;
    }
    auto out_ = appender!string();
    serialize(doc, out_);
    writeln(out_.data);
    return 0;
}