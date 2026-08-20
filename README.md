To set up on a new sever:

First add public SSH key, then

curl -fsSL https://raw.githubusercontent.com/tlun0911/server-bootstrap/main/bootstrap.sh \\
  | bash -s -- --hostname SERVER-NAME
