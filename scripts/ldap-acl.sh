#!/usr/bin/env bash
# scripts/ldap-acl.sh (identity-up runs it): the directory's access rules,
# from vault_dance. Applied over ldapi:// inside vbal-openldap (SASL EXTERNAL
# as the container's root: the only way to change cn=config). The whole
# olcAccess list is replaced in a known order, so a run is idempotent.
#   passwords   a person may change their own; anyone may bind with one
#               (auth); nobody may read one
#   everything  admin writes; keycloak-bind (Keycloak's federation) reads;
#               signed-in people read; anonymous sees nothing
# Without the last rule osixia's default hides ou=people from keycloak-bind,
# and every sign-in fails with "Invalid username or password" (found on the
# first sign-in, prompt 12).
set -euo pipefail
B="dc=balancing,dc=lab"
podman exec -i vbal-openldap ldapmodify -Q -Y EXTERNAL -H ldapi:/// >/dev/null <<LDIF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break
olcAccess: {1}to attrs=userPassword,shadowLastChange by self write by dn.exact="cn=admin,$B" write by anonymous auth by * none
olcAccess: {2}to * by dn.exact="cn=admin,$B" write by dn.exact="cn=keycloak-bind,ou=system,$B" read by users read by * none
LDIF
echo "ldap-acl: access rules applied (keycloak-bind reads the directory; passwords: auth only)"
