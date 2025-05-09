USE HederligeHarrysBilar;
GO

SELECT * -- Users Table, 
FROM Users.Users;

SELECT * -- LoginLogs Table, 
FROM Users.LoginLogs;

/*________________________________________________________________________________ Email settings and activation ______________________________________________________________________________________________________________________*/

-- Add a new account, change the "test" if you want to change anything otherwise just execute the code. I would recommend to not change anything at all.
EXEC msdb.dbo.sysmail_add_account_sp
	@account_name = 'Hederlinge Harrys Bilar AB',
	@description = 'Test mejl',
	@email_address = 'Testmejl@gmail.com',
	@display_name = 'Hederlinge Harrys Bilar AB',
	@mailserver_type = 'SMTP',
	@mailserver_name = 'smtp.gmail.com',
	@port = 587,
	@enable_ssl = 1,
	@username = 'Testmejl@gmail.com',
	@password = 'test test test test'; -- Google AppPassword, normally this is required so that the program can send an email to a Gmail account, that isn't something you need to go through.
										-- We added this code so that the Stored Procedures send emails when executed. So technically you don't need to change anything here.

/*________________________________________________________________________________ Register a new user (SP) ______________________________________________________________________________________________________________________*/

EXEC Register --Register a new account
    @Email = 'test@test.com', -- Enter your email
    @Password = 'Testtt1!', --Enter your password (Min. 8 Letters | Min. 1 Uppercase letter | Min. 1 Number | Min. 1 Symbol | Ex: Hejhej1!)
    @FirstName = 'Test', -- Enter your first name
    @LastName = 'Testsson', -- Enter your last name
	@PhoneNumber = '+46 74 452 05 50', -- Enter your phone number (+46 XX XXX XX XX is the recommended format)
    @Address = 'Testvägen 1', -- Enter your address
    @PostalCode = '165 56', -- Enter your postal code
    @City = 'Testtuna', -- Enter your city
	@Country = 'Testlandet'; -- Enter your country

/*________________________________________________________________________________ Verify your account (SP) ______________________________________________________________________________________________________________________*/

SELECT FirstName + ' ' + LastName AS FullName, -- Get your verification code
		VerificationToken, 
		VerificationTokenExpiry 
FROM Users.Users
WHERE Email = 'test@test.com' -- Enter your email

EXEC Verification 
    @Email = 'test@test.com', -- Enter your email
    @VerificationToken = ''; -- Enter your verification code

/*________________________________________________________________________________ Forgotten Password (SP) ______________________________________________________________________________________________________________________*/

EXEC ForgottenPassword -- Get your verification code / reset code to reset your password
	@Email = 'test@test.com' -- Enter your email

/*________________________________________________________________________________ Reset Password (SP) ______________________________________________________________________________________________________________________*/

SELECT FirstName + ' ' + LastName AS FullName, -- Get your verification code
		VerificationToken, 
		VerificationTokenExpiry 
FROM Users.Users
WHERE Email = 'test@test.com' -- Enter your email

EXEC SetForgottenPassword 
    @Email = 'test@test.com', -- Enter your email
    @NewPassword = 'Testtt12!', -- Enter your new password
	@VerificationToken = ''; -- Enter your verification code

/*________________________________________________________________________________ Login (SP) ______________________________________________________________________________________________________________________*/

EXEC Login 
    @Email = 'test@test.com', -- Enter your email
    @Password = 'Testtt12!', -- Enter your password
	@IPAddress = '29.85.156.124'; -- Enter your IP Address (IPv4 - X.X.X.X) 

/*________________________________________________________________________________ Views ______________________________________________________________________________________________________________________*/

SELECT * -- View to see all users recent login attempts
FROM UserLoginActivity; 

SELECT * -- View to see all users successful and failed login attempts
FROM UserLoginAttempts;

/*________________________________________________________________________________ Delete old logs ______________________________________________________________________________________________________________________*/

DELETE FROM Users.LoginLogs WHERE AttemptedAt < DATEADD(MONTH, -1, GETDATE()); 
-- This can be automated using "SQL Server Agent" so that it executes everyday or when you want it to, I'll add this code in case you don't want to do those extra steps and setup the "SQL Server Agent". This gets explained more in-depth via the documentation.

