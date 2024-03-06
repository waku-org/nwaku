import 
  osproc, 
  os, 
  httpclient, 
  strutils

proc getPublicIP(): string =
  let client = newHttpClient()
  try:
    let response = client.get("http://api.ipify.org")
    return response.body
  except Exception as e:
    echo "Could not fetch public IP: " & e.msg
    return "127.0.0.1"

# Function to generate a self-signed certificate
proc generateSelfSignedCertificate*(certPath: string, keyPath: string) : int =
  
  # Ensure the OpenSSL is installed
  if findExe("openssl") == "":
    echo "OpenSSL is not installed or not in the PATH."
    return 1

  let publicIP = getPublicIP()
  
  if publicIP != "127.0.0.1":
    echo "Your public IP address is: ", publicIP 
  
  # Command to generate private key and cert
  let 
    cmd = "openssl req -x509 -newkey rsa:4096 -keyout " & keyPath & " -out " & certPath &
            " -sha256 -days 3650 -nodes -subj '/C=XX/ST=StateName/L=CityName/O=CompanyName/OU=CompanySectionName/CN=" & 
            publicIP & "'"
    res = execCmd(cmd)

  if res == 0:
    echo "Successfully generated self-signed certificate and key."
  else:
    echo "Failed to generate certificate and key."
  
  return res
  