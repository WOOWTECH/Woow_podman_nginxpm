#!/usr/bin/env python3
"""Render a `podman inspect --format` template against a captured inspect JSON file.

    tests/gotmpl.py <inspect.json> <template>      # -> what podman would print

Why this exists: `podman inspect --format` is Go text/template over podman's own structs, so
a field is addressed by its Go FIELD name, not by the lowercase JSON tag that shows up in
`podman inspect` output. define.InspectHostPort is

    type InspectHostPort struct {
        HostIP   string `json:"HostIp"`
        HostPort string `json:"HostPort"`
    }

so {{.HostIP}} works and {{.HostIp}} makes podman fail the whole template. Because the JSON
and the template disagree, no test that only looks at inspect JSON can catch that, and a
`while read` loop over a failed template quietly reads nothing: that is how the missing
30142 shipped. This renderer therefore resolves names the way Go does, from the field names,
and refuses a JSON tag whose field is spelled differently (JSON_TAG_FIELDS below).

Supported subset - exactly what scripts/common.sh uses:
    {{range $k, $v := .Path}} {{range .Path}} {{range $v}} ... {{end}}
    {{.Field.Path}}  {{.}}  {{$var}}  {{println}}  {{println .}}
Two podman behaviours are reproduced: the format is executed once per inspected object (as
if wrapped in {{range .}}, which is also why {{$.Field}} cannot reach an object), and podman
appends a newline after each object - the blank trailing row a {{println}} template leaves.
Map keys are visited in sorted order, like Go.
"""
import json
import re
import sys

# podman 4.9.3 inspect structs: every Go field whose JSON tag is spelled differently.
# Keyed by the JSON tag, since that is what a captured fixture contains.
JSON_TAG_FIELDS = {
    "HostIp": ("HostIP", "define.InspectHostPort"),
}
FIELD_TO_TAG = {field: tag for tag, (field, _t) in JSON_TAG_FIELDS.items()}

ACTION = re.compile(r"{{(.*?)}}", re.S)
RANGE_KV = re.compile(r"^range\s+(\$[A-Za-z_]\w*)\s*,\s*(\$[A-Za-z_]\w*)\s*:=\s*(\S+)$")
RANGE_1 = re.compile(r"^range\s+(\S+)$")


class TemplateError(Exception):
    pass


def field(node, name):
    """One .Name step, with Go's struct-field semantics."""
    if name in JSON_TAG_FIELDS and JSON_TAG_FIELDS[name][0] != name:
        f, typ = JSON_TAG_FIELDS[name]
        raise TemplateError(
            "can't evaluate field %s in type %s (the JSON tag; the Go field is %s)" % (name, typ, f)
        )
    if not isinstance(node, dict):
        raise TemplateError("can't evaluate field %s in type %s" % (name, type(node).__name__))
    if name in FIELD_TO_TAG and FIELD_TO_TAG[name] in node:
        return node[FIELD_TO_TAG[name]]
    if name in node:
        return node[name]
    raise TemplateError("can't evaluate field %s in type %s" % (name, "map[string]interface {}"))


def evaluate(expr, dot, scope):
    if expr == ".":
        return dot
    if expr.startswith("$"):
        name = expr.split(".")[0]
        if name not in scope:
            raise TemplateError("undefined variable %s" % name)
        node = scope[name]
        for part in expr.split(".")[1:]:
            node = field(node, part)
        return node
    if expr.startswith("."):
        node = dot
        for part in expr.lstrip(".").split("."):
            node = field(node, part)
        return node
    raise TemplateError("unsupported expression %r" % expr)


def render_string(value):
    if value is None:
        return "<no value>"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (dict, list)):
        return json.dumps(value)
    return str(value)


def parse(template):
    """-> a list of ('text', s) / ('action', s) / ('range', head, body) nodes."""
    nodes, stack, pos = [], [], 0
    for m in ACTION.finditer(template):
        if m.start() > pos:
            nodes.append(("text", template[pos:m.start()]))
        pos = m.end()
        action = m.group(1).strip()
        if action.startswith("range"):
            stack.append((action, nodes))
            nodes = []
        elif action == "end":
            if not stack:
                raise TemplateError("unexpected {{end}}")
            head, outer = stack.pop()
            outer.append(("range", head, nodes))
            nodes = outer
        else:
            nodes.append(("action", action))
    if stack:
        raise TemplateError("missing {{end}}")
    if pos < len(template):
        nodes.append(("text", template[pos:]))
    return nodes


def execute(nodes, dot, scope, out):
    for node in nodes:
        if node[0] == "text":
            out.append(node[1])
        elif node[0] == "action":
            action = node[1]
            if action == "println":
                out.append("\n")
            elif action.startswith("println"):
                out.append(render_string(evaluate(action.split(None, 1)[1], dot, scope)) + "\n")
            else:
                out.append(render_string(evaluate(action, dot, scope)))
        else:
            _, head, body = node
            kv, one = RANGE_KV.match(head), RANGE_1.match(head)
            if kv:
                kvar, vvar, expr = kv.groups()
            elif one:
                kvar, vvar, expr = None, None, one.group(1)
            else:
                raise TemplateError("unsupported range %r" % head)
            value = evaluate(expr, dot, scope)
            if isinstance(value, dict):
                items = [(k, value[k]) for k in sorted(value)]  # Go sorts map keys
            elif isinstance(value, list):
                items = list(enumerate(value))
            elif value is None:
                items = []
            else:
                raise TemplateError("range over a %s" % type(value).__name__)
            for key, item in items:
                inner = dict(scope)
                if kvar:
                    inner[kvar], inner[vvar] = key, item
                execute(body, item, inner, out)


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(__doc__)
        return 64
    objects = json.load(open(argv[1]))
    if not isinstance(objects, list):  # podman always prints an array
        objects = [objects]
    nodes = parse(argv[2])
    out = []
    for obj in objects:
        # "$" is the whole array, the way podman's implicit {{range .}} leaves it.
        execute(nodes, obj, {"$": objects}, out)
        out.append("\n")
    sys.stdout.write("".join(out))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except TemplateError as exc:
        sys.stderr.write("Error: template: inspect:1: executing \"inspect\": %s\n" % exc)
        sys.exit(125)  # podman's exit code for a failed template
