$pw  = Read-Host -AsSecureString "PFX password"
$c   = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2("C:\Users\veeamapool\Downloads\<INSERT DATA>_with_intermediate.pfx", $pw, "Exportable")
$c | fl Subject, Thumbprint, NotAfter, HasPrivateKey