# One line per Keycloak user session: start, last access, IP, clients using it.
.[]
| "\(.start/1000 | todate)\tlast=\(.lastAccess/1000 | todate)\t\(.ipAddress)\tclients=\(.clients | [.[]] | join(","))"
