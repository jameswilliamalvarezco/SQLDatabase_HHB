/*________________________________________________________________________________ Database ______________________________________________________________________________________________________________________*/

USE master; -- Makes sure that there's no other database selected and so that we can execute the code and create a new database. 

IF EXISTS(SELECT * FROM sys.databases WHERE name = 'HederligeHarrysBilar') -- Drops the database if it exists
	BEGIN
		ALTER DATABASE HederligeHarrysBilar SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
		DROP DATABASE HederligeHarrysBilar
	END
GO

IF NOT EXISTS(SELECT * FROM sys.databases WHERE name = 'HederligeHarrysBilar') -- Creates the database if it doesn't exist
	BEGIN
		CREATE DATABASE [HederligeHarrysBilar]
	END
GO

/*________________________________________________________________________________ Schema ______________________________________________________________________________________________________________________*/

USE HederligeHarrysBilar; -- Makes sure to choose the new database we just created 
GO

SET NOCOUNT ON;

GO
CREATE SCHEMA Users; -- Creates a schema to make it easier to find the tables per department and makes it easier for sorting
GO

/*________________________________________________________________________________ Tables ______________________________________________________________________________________________________________________*/

CREATE TABLE Users.Users ( -- Creates a table for Users
	UserID INT PRIMARY KEY IDENTITY(1,1),
	Email NVARCHAR(255) UNIQUE NOT NULL,
	PasswordHash NVARCHAR(128) NOT NULL,
	Salt NVARCHAR(50) NOT NULL,
	FirstName NVARCHAR(50) NOT NULL,
	LastName NVARCHAR(50) NOT NULL,
	Role CHAR(1) CHECK(Role IN ('A', 'C')) DEFAULT 'C' NOT NULL,
	PhoneNumber NVARCHAR(20),
	Address NVARCHAR(255),
	PostalCode NVARCHAR(10),
	City NVARCHAR(50),
	Country NVARCHAR(60),
	IsVerified BIT DEFAULT 0,
	VerificationToken UNIQUEIDENTIFIER,
	VerificationTokenExpiry DATETIME,
	IsActive BIT DEFAULT 0,
	IsLockedOut BIT DEFAULT 0,
	CreatedAt DATETIME DEFAULT GETDATE(),
	UpdatedAt DATETIME DEFAULT GETDATE(),
	ValidTo AS DATEADD(MONTH, 6, CreatedAt)
	);

CREATE TABLE Users.LoginLogs ( -- Creates a table for Login Logs
	LogID INT PRIMARY KEY IDENTITY(1,1),
	UserID INT NOT NULL,
	FOREIGN KEY(UserID) References Users.Users(UserID),
	IPAddress NVARCHAR(45) NOT NULL,
	Email NVARCHAR(255) NOT NULL,
	AttemptedAt DATETIME DEFAULT GETDATE() NOT NULL,
	IsSuccess BIT NOT NULL
	);

/*________________________________________________________________________________ Email settings and activation ______________________________________________________________________________________________________________________*/

-- Activate Database Mail.
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;

EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE;

-- Email Profile, Settings
IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = 'Hederlige Harrys Bilar AB')
BEGIN
    EXEC msdb.dbo.sysmail_delete_profile_sp @profile_name = 'Hederlige Harrys Bilar AB';
END

-- Add the new profile
EXEC msdb.dbo.sysmail_add_profile_sp
	@profile_name = 'Hederlige Harrys Bilar AB',
	@description = 'HHB ABs profile for sending emails';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = 'Hederlige Harrys Bilar AB') -- Removes the account if it exists.
BEGIN
    EXEC msdb.dbo.sysmail_delete_account_sp @account_name = 'Hederlige Harrys Bilar AB';
END

/*________________________________________________________________________________ Register a new user (SP) ______________________________________________________________________________________________________________________*/

IF OBJECT_ID('Register', 'P') IS NOT NULL
    DROP PROCEDURE Register;
GO
CREATE PROCEDURE Register 
    @Email NVARCHAR(255),
    @Password NVARCHAR(128),
    @FirstName NVARCHAR(50),
    @LastName NVARCHAR(50),
    @PhoneNumber NVARCHAR(20),
    @Address NVARCHAR(255),
    @PostalCode NVARCHAR(15),
    @City NVARCHAR(100),
    @Country NVARCHAR(100)
AS
BEGIN
	BEGIN TRY
        IF @Email NOT LIKE '%_@_%._%' -- Makes sure that the email follows a specific format which ensures that that it isn't possible to create an email address that doesn't follow the format.
        BEGIN
            RAISERROR('Invalid e-mail address. You seem to not have followed the correct format, here is an example email: test@test.se', 16, 1);
            RETURN;
        END

		IF LEN(@Password) < 8 -- Minimum of 8 letters
		OR PATINDEX('%[A-Z]%', @Password) = 0 -- Minimum of 1 uppercase letter
		OR PATINDEX('%[0-9]%', @Password) = 0 -- Minimum of 1 number
		OR PATINDEX('%[^A-Za-z0-9]%', @Password) = 0 -- Minimum of 1 symbol
		BEGIN
			RAISERROR('The password must have at least:
- 8 Letters
- 1 Uppercase letter
- 1 Number
- 1 Symbol', 16, 1);
			RETURN;
		END

        IF EXISTS(SELECT 1 FROM Users.Users WHERE Email = @Email) -- Checks if the email exists
        BEGIN
            RAISERROR('The specified email address is already in use.', 16, 1);
            RETURN;
        END

        BEGIN TRANSACTION;

		DECLARE @Salt NVARCHAR(50) = CONVERT(NVARCHAR(50), NEWID()); -- Generates Salt for users and for better security, the Salt also gets added to the PasswordHash 
		DECLARE @VerificationToken UNIQUEIDENTIFIER = NEWID(); -- Generates the Verification Token 
		DECLARE @VerificationTokenExpiry DATETIME = DATEADD(DAY, 1, GETDATE()); -- Makes sure that the Verification Code is only valid for 1 day
		DECLARE @Message NVARCHAR(MAX); 
		SET @Message = 'Hello ' + @FirstName + ' ' + @LastName + '! Thanks for creating an account, this is your verification code: ' + CAST(@VerificationToken AS NVARCHAR(36));

        INSERT INTO Users.Users ( -- Add the user to the Users table
            Email, PasswordHash, Salt, FirstName, LastName, 
            PhoneNumber, Address, PostalCode, City, Country, VerificationToken, VerificationTokenExpiry 
        )
        VALUES (
            @Email, CONVERT(VARCHAR(128), HASHBYTES('SHA2_512', @Password + @Salt), 1), @Salt, @FirstName, @LastName,
            @PhoneNumber, @Address, @PostalCode, @City, @Country, @VerificationToken, @VerificationTokenExpiry
        )

			EXEC msdb.dbo.sp_send_dbmail  
				@profile_name = 'Hederlige Harrys Bilar AB',  
				@recipients = @Email,  
				@subject = 'Verify your HHB account!',  
				@body = @Message;

			PRINT 'Your account has been created, an email has been sent to ' + @Email + '. Please verify your account before logging in.';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        ROLLBACK TRANSACTION;
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR (@ErrorMessage, 16, 1);
    END CATCH;
END; 
GO

/*________________________________________________________________________________ Verify your account (SP) ______________________________________________________________________________________________________________________*/

IF OBJECT_ID('Verification', 'P') IS NOT NULL
    DROP PROCEDURE Verification;
GO
CREATE PROCEDURE Verification 
	@Email NVARCHAR(255),
    @VerificationToken UNIQUEIDENTIFIER
AS
BEGIN
	BEGIN TRY
        IF EXISTS(SELECT 1 FROM Users.Users WHERE Email = @Email AND VerificationToken = @VerificationToken AND VerificationTokenExpiry > GETDATE()) -- Checks if the email exists
        BEGIN
            UPDATE Users.Users
			SET IsVerified = 1, 
				IsActive = 1, 
				VerificationToken = NULL, 
				VerificationTokenExpiry = NULL, 
				IsLockedOut = IsLockedOut
			WHERE Email = @Email

			PRINT 'Your email has been verified, you can now login to your account.';
        END
		ELSE
		BEGIN
			RAISERROR('Verification failed. Invalid email or verification code and/or the verification code has expired.', 16, 1);
		END
	END TRY
	BEGIN CATCH
		DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
		RAISERROR(@ErrorMessage, 16, 1);
	END CATCH;
END;
GO

/*________________________________________________________________________________ Forgotten Password (SP) ______________________________________________________________________________________________________________________*/

IF OBJECT_ID('ForgottenPassword', 'P') IS NOT NULL
    DROP PROCEDURE ForgottenPassword;
GO
CREATE PROCEDURE ForgottenPassword 
    @Email NVARCHAR(255)
AS
BEGIN
	BEGIN TRY

		DECLARE @IsLockedOut BIT;
		SELECT @IsLockedOut = IsLockedOut FROM Users.Users WHERE Email = @Email;

		
		IF @IsLockedOut = 1 -- Checks if the account is locked, if it's locked then it won't change the password
		BEGIN
			RAISERROR('Your account is locked! Please contact our customer service to unlock your account.', 16, 1);
			RETURN;
		END

        IF NOT EXISTS(SELECT 1 FROM Users.Users WHERE Email = @Email) -- Checks if the email exists
        BEGIN
            RAISERROR('The email does not exist, please try again!', 16, 1);
            RETURN;
        END

        BEGIN TRANSACTION;

		DECLARE @FirstName NVARCHAR(50), @LastName NVARCHAR(50); -- Gets the users full name
		SELECT @FirstName = FirstName, @LastName = LastName FROM Users.Users WHERE Email = @Email;

		DECLARE @VerificationToken UNIQUEIDENTIFIER = NEWID(); -- Generates Verification Token 
		DECLARE @VerificationTokenExpiry DATETIME = DATEADD(DAY, 1, GETDATE()); -- Makes sure that the Verification Code is only valid for 1 day
		UPDATE Users.Users -- Updates the users verification code in the database.
		SET VerificationToken = @VerificationToken, VerificationTokenExpiry = @VerificationTokenExpiry
		WHERE Email = @Email;

		DECLARE @Message NVARCHAR(MAX); 
		SET @Message = 'Hello ' + @FirstName + ' ' + @LastName + '! We have recieved your request to reset your password. Use this verification code to reset your password: ' + CAST(@VerificationToken AS NVARCHAR(36)) + '. The code is valid for 24 hours. If you have not requested to reset your password then you can ignore this email.';

			EXEC msdb.dbo.sp_send_dbmail  -- Sending the email
				@profile_name = 'Hederlige Harrys Bilar AB',  
				@recipients = @Email,  
				@subject = 'Verify your HHB account!',  
				@body = @Message;

			PRINT 'A one-time code has been sent to ' + @Email + '. Enter the code on the recovery page to create a new password. The code is valid for 24 hours. If you have not requested to reset your password then you can ignore this email.';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        ROLLBACK TRANSACTION;
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR (@ErrorMessage, 16, 1);
    END CATCH;
END; 
GO

/*________________________________________________________________________________ Reset Password (SP) ______________________________________________________________________________________________________________________*/

IF OBJECT_ID('SetForgottenPassword', 'P') IS NOT NULL
	DROP PROCEDURE SetForgottenPassword; 
GO
CREATE PROCEDURE SetForgottenPassword
	@Email NVARCHAR(255),
	@VerificationToken UNIQUEIDENTIFIER,
	@NewPassword NVARCHAR(128)
AS
BEGIN
	BEGIN TRY

		DECLARE @Salt NVARCHAR(50);
		DECLARE @OldPasswordHash NVARCHAR(128);


		SELECT @Salt = Salt, @OldPasswordHash = PasswordHash -- Gets Salt and PasswordHash
		FROM Users.Users
		WHERE Email = @Email;


        IF NOT EXISTS(SELECT 1 FROM Users.Users WHERE Email = @Email AND VerificationToken = @VerificationToken AND VerificationTokenExpiry > GETDATE()) -- Checks if the email and verification token is valid
        BEGIN
			RAISERROR('You cannot change the password. Invalid email or verification code and/or the verification code has expired.', 16, 1);
			RETURN;
        END

		IF LEN(@NewPassword) < 8 -- Minimum of 8 letters
		OR PATINDEX('%[A-Z]%', @NewPassword) = 0 -- Minimum of 1 uppercase letter
		OR PATINDEX('%[0-9]%', @NewPassword) = 0 -- Minimum of 1 number
		OR PATINDEX('%[^A-Za-z0-9]%', @NewPassword) = 0 -- Minimum of 1 symbol
		BEGIN
			RAISERROR('The password must have at least:
- 8 Letters
- 1 Uppercase letter
- 1 Number
- 1 Symbol', 16, 1);
			RETURN;
		END

		SET @Salt = ISNULL(@Salt, NEWID()); -- Generate a new PasswordHash
		DECLARE @NewPasswordHash NVARCHAR(128) = CONVERT(VARCHAR(128), HASHBYTES('SHA2_512', @NewPassword + @Salt), 1);

		IF @NewPasswordHash = @OldPasswordHash -- Check if the new password is the same as the old one
		BEGIN
			RAISERROR('Your new password cannot be the same as your old password, please try again.', 16, 1);
			RETURN;
		END

		UPDATE Users.Users -- Update the new password and empty the verification token
		SET PasswordHash = @NewPasswordHash, 
			IsVerified = 1, 
			IsActive = 1, 
			VerificationToken = NULL, 
			VerificationTokenExpiry = NULL,
			IsLockedOut = 0
		WHERE Email = @Email;

		PRINT 'The verification is successful, a new password has been set.';
		
	END TRY
	BEGIN CATCH
		DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
		RAISERROR(@ErrorMessage, 16, 1);
	END CATCH;
END;
GO

/*________________________________________________________________________________ Login (SP) ______________________________________________________________________________________________________________________*/

IF OBJECT_ID('Login', 'P') IS NOT NULL
    DROP PROCEDURE Login;
GO
CREATE PROCEDURE Login 
    @Email NVARCHAR(255),
    @Password NVARCHAR(128),
    @IPAddress NVARCHAR(45)
AS
BEGIN
    BEGIN TRY
        IF NOT EXISTS(SELECT 1 FROM Users.Users WHERE Email = @Email) -- Check if the email exists
        BEGIN
            INSERT INTO Users.LoginLogs (UserID, Email, IPAddress, AttemptedAt, IsSuccess)
            VALUES (NULL, @Email, @IPAddress, GETDATE(), 0);
            RAISERROR('Invalid email.', 16, 1);
            RETURN;
        END

        DECLARE @UserID INT;
        DECLARE @PasswordHash NVARCHAR(128);
        DECLARE @Salt NVARCHAR(50);
        DECLARE @IsVerified BIT;
        DECLARE @IsActive BIT;
        DECLARE @IsLockedOut BIT;
        DECLARE @FailedAttempts INT;
        DECLARE @IsSuccess BIT = 0;

        SELECT
            @UserID = UserID, 
            @PasswordHash = PasswordHash,
            @Salt = Salt,
            @IsVerified = IsVerified,
            @IsActive = IsActive,
            @IsLockedOut = IsLockedOut
        FROM Users.Users
        WHERE Email = @Email;

        -- Check if the account is locked due to too many login attempts
        SELECT @FailedAttempts = COUNT(*)
        FROM Users.LoginLogs
        WHERE UserID = @UserID AND IsSuccess = 0 AND AttemptedAt >= DATEADD(MINUTE, -15, GETDATE());

        IF @FailedAttempts >= 3
        BEGIN
            UPDATE Users.Users
            SET IsLockedOut = 1
            WHERE UserID = @UserID;

            INSERT INTO Users.LoginLogs (UserID, Email, IPAddress, AttemptedAt, IsSuccess)
            VALUES (@UserID, @Email, @IPAddress, GETDATE(), 0);
            RAISERROR('Your account has been locked due to too many login attempts. To unlock your account, please contact our customer service.', 16, 1); 
            RETURN;
        END

        IF @IsLockedOut = 1 -- Checks if the account is locked
        BEGIN
            INSERT INTO Users.LoginLogs (UserID, Email, IPAddress, AttemptedAt, IsSuccess)
            VALUES (@UserID, @Email, @IPAddress, GETDATE(), 0);
            RAISERROR('Your account is locked, please contact our customer service.', 16, 1);
            RETURN;
        END

        IF @IsVerified = 0 -- Checks if account is verified
        BEGIN
            INSERT INTO Users.LoginLogs (UserID, Email, IPAddress, AttemptedAt, IsSuccess)
            VALUES (@UserID, @Email, @IPAddress, GETDATE(), 0);
            RAISERROR('Your account has not been verified, please verify your account via email.', 16, 1);
            RETURN;
        END

        IF @IsActive = 0 -- Checks if the account is active
        BEGIN
            INSERT INTO Users.LoginLogs (UserID, Email, IPAddress, AttemptedAt, IsSuccess)
            VALUES (@UserID, @Email, @IPAddress, GETDATE(), 0);
            RAISERROR('Your account is inactive.', 16, 1);
            RETURN;
        END

        DECLARE @HashedPassword NVARCHAR(128) = CONVERT(VARCHAR(128), HASHBYTES('SHA2_512', @Password + @Salt), 1); -- Hash och salt password

        IF @HashedPassword <> @PasswordHash
        BEGIN
            INSERT INTO Users.LoginLogs(UserID, Email, IPAddress, AttemptedAt, IsSuccess)
            VALUES(@UserID, @Email, @IPAddress, GETDATE(), 0);

            RAISERROR('Wrong password.', 16, 1);
            RETURN;
        END

        SET @IsSuccess = 1;

        INSERT INTO Users.LoginLogs (UserID, Email, IPAddress, AttemptedAt, IsSuccess)
        VALUES (@UserID, @Email, @IPAddress, GETDATE(), 1);

        PRINT 'Login Successful'; -- Successful login

    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@ErrorMessage, 16, 1);
    END CATCH;
END;
GO

/*________________________________________________________________________________ User Data Insert ______________________________________________________________________________________________________________________*/

INSERT INTO Users.Users
	(Email, PasswordHash, Salt, FirstName, LastName, Role, PhoneNumber, Address, PostalCode, City, Country)
VALUES
    ('johan.lindberg@hhb.com', '0xA1B2C3D4E5F64', '1D6C1083-797D-4389-AD30-C813F78A8F7B', 'Johan', 'Lindberg', 'A', '+46 72 903 03 54', 'Storgatan 12', '111 22', 'Stockholm', 'Sverige'),
    ('erik.nilsson@hhb.com', '0xA1B2C3D4E5F66', '2E6C1083-797D-4389-AD30-C813F78A8F7C', 'Erik', 'Nilsson', 'A', '+46 72 903 45 67', 'Kungsgatan 78', '114 89', 'Malmö', 'Sverige'),
    ('karl.johansson@hhb.com', '0xA1B2C3D4E5F68', '3F6C1083-797D-4389-AD30-C813F78A8F7D', 'Karl', 'Johansson', 'A', '+46 73 901 12 34', 'Linnégatan 22', '116 78', 'Västerås', 'Sverige'),
    ('oskar.persson@hhb.com', '0xA1B2C3D4E5F63', '4G6C1083-797D-4389-AD30-C813F78A8F7E', 'Oskar', 'Persson', 'A', '+46 74 902 56 78', 'Bergsgatan 5', '118 90', 'Linköping', 'Sverige'),
    ('mattias.fredriksson@hhb.com', '0xA1B2C3D4E5F655', '5H6C1083-797D-4389-AD30-C813F78A8F7F', 'Mattias', 'Fredriksson', 'A', '+46 75 903 78 90', 'Södra Vägen 8', '120 11', 'Lund', 'Sverige'),
    ('peter.holm@hhb.com', '0xA1B2C3D4E5F666', '6I6C1083-797D-4389-AD30-C813F78A8F80', 'Peter', 'Holm', 'A', '+46 76 904 90 12', 'Västra Hamngatan 16', '122 33', 'Sundsvall', 'Sverige'),
    ('robin.hedlund@hhb.com', '0xA1B2C3D4E5F666', '7J6C1083-797D-4389-AD30-C813F78A8F81', 'Robin', 'Hedlund', 'A', '+46 77 905 12 34', 'Skeppsbron 7', '124 55', 'Norrköping', 'Sverige'),
    ('daniel.ek@hhb.com', '0xA1B2C3D4E5F6555', '8K6C1083-797D-4389-AD30-C813F78A8F82', 'Daniel', 'Ek', 'A', '+46 78 906 34 56', 'Götgatan 3', '126 77', 'Luleå', 'Sverige'),
    ('anna.svensson@gmail.com', '0xA1B2C3D4E5F6', '9L6C1083-797D-y4389-AD30-C813F78A8F83', 'Anna', 'Svensson', 'C', '+46 72 001 23 45', 'Drottninggatan 45', '113 56', 'Göteborg', 'Sverige'),
    ('lisa.andersson@yahoo.com', '0xB2C3D4E5F6G7', 'AL6C1083-797D-4389-AD30-C813F78A8F84', 'Lisa', 'Andersson', 'C', '+46 73 002 34 56', 'Vasagatan 9', '115 67', 'Uppsala', 'Sverige'),
    ('emma.karlsson@outlook.com', '0xC3D4E5F6G7H8', 'BL6C1083-797D-4389-AD30-C813F78A8F85', 'Emma', 'Karlsson', 'C', '+46 74 003 45 67', 'Östra Storgatan 33', '117 89', 'Örebro', 'Sverige'),
    ('henrik.stenberg@yahoo.com', '0xD4E5F6G7H8I9', 'CL6C1083-797D-4389-AD30-C813F78A8F86', 'Henrik', 'Stenberg', 'C', '+46 75 004 56 78', 'Lilla Nygatan 5', '130 21', 'Falun', 'Sverige'),
    ('linda.bergstrom@outlook.com', '0xE5F6G7H8I9J0', 'DL6C1083-797D-4389-AD30-C813F78A8F87', 'Linda', 'Bergström', 'C', '+46 76 005 67 89', 'Östra Hamngatan 18', '131 32', 'Östersund', 'Sverige'),
    ('johan.nyberg@gmail.com', '0xF6G7H8I9J0K1', 'EL6C1083-797D-4389-AD30-C813F78A8F88', 'Johan', 'Nyberg', 'C', '+46 77 006 78 90', 'Storgatan 12', '132 43', 'Växjö', 'Sverige'),
    ('sara.ekman@yahoo.com', '0xG7H8I9J0K1L2', 'FL6C1083-797D-4389-AD30-C813F78A8F89', 'Sara', 'Ekman', 'C', '+46 78 007 89 01', 'Kungsgatan 78', '133 54', 'Gävle', 'Sverige'),
    ('maria.lind@outlook.com', '0xH8I9J0K1L2M3', 'GL6C1083-797D-4389-AD30-C813F78A8F90', 'Maria', 'Lind', 'C', '+46 79 008 90 12', 'Bergsgatan 5', '134 65', 'Jönköping', 'Sverige'),
    ('oliver.nilsson@gmail.com', '0xI9J0K1L2M3N4', 'HL6C1083-797D-4389-AD30-C813F78A8F91', 'Oliver', 'Nilsson', 'C', '+46 70 009 12 34', 'Södra Vägen 8', '135 76', 'Helsingborg', 'Sverige'),
    ('kristin.forsberg@yahoo.com', '0xJ0K1L2M3N4O5', 'IL6C1083-797D-4389-AD30-C813F78A8F92', 'Kristin', 'Forsberg', 'C', '+46 71 010 23 45', 'Västra Hamngatan 16', '136 87', 'Karlstad', 'Sverige'),
    ('markus.holm@outlook.com', '0xK1L2M3N4O5P6', 'JL6C1083-797D-4389-AD30-C813F78A8F93', 'Markus', 'Holm', 'C', '+46 72 011 34 56', 'Skeppsbron 7', '137 98', 'Nyköping', 'Sverige'),
    ('josefine.eriksson@gmail.com', '0xL2M3N4O5P6Q7', 'KL6C1083-797D-4389-AD30-C813F78A8F94', 'Josefine', 'Eriksson', 'C', '+46 73 012 45 67', 'Götgatan 3', '138 09', 'Borås', 'Sverige'),
    ('sebastian.wahlstrom@yahoo.com', '0xM3N4O5P6Q7R8', 'LL6C1083-797D-4389-AD30-C813F78A8F95', 'Sebastian', 'Wahlström', 'C', '+46 74 013 56 78', 'Drottningtorget 10', '139 10', 'Halmstad', 'Sverige'),
    ('therese.larsson@outlook.com', '0xN4O5P6Q7R8S9', 'ML6C1083-797D-4389-AD30-C813F78A8F96', 'Therese', 'Larsson', 'C', '+46 75 014 67 89', 'Torggatan 22', '140 21', 'Sundsvall', 'Sverige'),
    ('patrik.malmstrom@gmail.com', '0xO5P6Q7R8S9T0', 'NL6C1083-797D-4389-AD30-C813F78A8F97', 'Patrik', 'Malmström', 'C', '+46 76 015 78 90', 'Norra Storgatan 55', '141 32', 'Skövde', 'Sverige'),
    ('hanna.lundqvist@yahoo.com', '0xP6Q7R8S9T0U1', 'OL6C1083-797D-4389-AD30-C813F78A8F98', 'Hanna', 'Lundqvist', 'C', '+46 77 016 89 01', 'Övre Slottsgatan 12', '142 43', 'Trollhättan', 'Sverige'),
    ('victor.bjork@outlook.com', '0xQ7R8S9T0U1V2', 'PL6C1083-797D-4389-AD30-C813F78A8F99', 'Victor', 'Björk', 'C', '+46 78 017 90 12', 'Kungsgatan 34', '143 54', 'Kristianstad', 'Sverige'),
    ('elin.fransson@gmail.com', '0xR8S9T0U1V2W3', 'QL6C1083-797D-4389-AD30-C813F78A8F100', 'Elin', 'Fransson', 'C', '+46 79 018 12 34', 'Lilla Bergsgatan 5', '144 65', 'Kalmar', 'Sverige'),
    ('alexander.wallin@yahoo.com', '0xS9T0U1V2W3X4', 'RL6C1083-797D-4389-AD30-C813F78A8F101', 'Alexander', 'Wallin', 'C', '+46 70 019 23 45', 'Östra Hamngatan 22', '145 76', 'Luleå', 'Sverige'),
    ('nathalie.sandberg@outlook.com', '0xT0U1V2W3X4Y5', 'SL6C1083-797D-4389-AD30-C813F78A8F102', 'Nathalie', 'Sandberg', 'C', '+46 71 020 34 56', 'Storgatan 90', '146 87', 'Karlskrona', 'Sverige'),
    ('gustav.holmgren@gmail.com', '0xU1V2W3X4Y5Z6', 'TL6C1083-797D-4389-AD30-C813F78A8F103', 'Gustav', 'Holmgren', 'C', '+46 72 021 45 67', 'Skeppsbron 10', '147 98', 'Visby', 'Sverige'),
    ('sofie.nilsson@yahoo.com', '0xV2W3X4Y5Z6A7', 'UL6C1083-797D-4389-AD30-C813F78A8F104', 'Sofie', 'Nilsson', 'C', '+46 73 022 56 78', 'Vasagatan 20', '148 09', 'Umeå', 'Sverige');


INSERT INTO Users.LoginLogs 
	(UserID, IPAddress, Email, AttemptedAt, IsSuccess)
VALUES
	(17, '79.85.156.124', 'oliver.nilsson@gmail.com', '2025-02-12 01:05:00', 0),
	(17, '79.85.156.124', 'oliver.nilsson@gmail.com', '2025-02-12 01:10:00', 0),
	(17, '79.85.156.124', 'oliver.nilsson@gmail.com', '2025-02-12 01:15:00', 1),
	(18, '79.85.156.127', 'kristin.forsberg@yahoo.com', '2025-02-13 02:05:00', 1),
	(18, '79.85.156.127', 'kristin.forsberg@yahoo.com', '2025-02-13 02:10:00', 1),
	(19, '79.85.156.129', 'markus.holm@outlook.com', '2025-02-14 03:05:00', 0),
	(19, '79.85.156.129', 'markus.holm@outlook.com', '2025-02-14 03:10:00', 0),
	(19, '79.85.156.129', 'markus.holm@outlook.com', '2025-02-14 03:15:00', 0),
	(20, '79.85.156.132', 'josefine.eriksson@gmail.com', '2025-02-15 04:05:00', 1);

/*________________________________________________________________________________ Views ______________________________________________________________________________________________________________________*/

GO

IF OBJECT_ID('UserLoginActivity', 'V') IS NOT NULL
    DROP VIEW UserLoginActivity;
GO

CREATE VIEW UserLoginActivity AS
	WITH RecentLogins AS 
	(
    SELECT 
        UserID, 
        MAX(CASE WHEN IsSuccess = 1 THEN AttemptedAt END) AS LastSuccessfulLogin,
        MAX(CASE WHEN IsSuccess = 0 THEN AttemptedAt END) AS LastFailedLogin
    FROM Users.LoginLogs
    GROUP BY UserID
	)

	SELECT 
		u.Email,
		u.FirstName + ' ' + u.LastName AS FullName,
		COALESCE(r.LastSuccessfulLogin, NULL) AS LastSuccessfulLogin,
		COALESCE(r.LastFailedLogin, NULL) AS LastFailedLogin
	FROM Users.Users u
	LEFT JOIN RecentLogins r ON u.UserID = r.UserID 
GO

IF OBJECT_ID('UserLoginAttempts', 'V') IS NOT NULL
	DROP VIEW UserLoginAttempts;
GO

CREATE VIEW UserLoginAttempts AS
	SELECT Email, w
	IPAddress, 
	AttemptedAt,
	SUM(CASE WHEN IsSuccess = 1 THEN 1 ELSE 0 END) OVER(PARTITION BY IPAddress ORDER BY AttemptedAt) AS SuccessfulAttempts,
	SUM(CASE WHEN IsSuccess = 0 THEN 1 ELSE 0 END) OVER(PARTITION BY IPAddress ORDER BY AttemptedAt) AS FailedAttempts,
	COUNT(*) OVER(PARTITION BY IPAddress ORDER BY AttemptedAt) AS TotalAttempts,
	ROUND(AVG(CAST(IsSuccess AS FLOAT)) OVER(PARTITION BY IPAddress ORDER BY AttemptedAt), 2) AS AVGSuccessfulAttempts
	FROM Users.LoginLogs
GO

/*________________________________________________________________________________ Index ______________________________________________________________________________________________________________________*/

-- Users table
CREATE UNIQUE INDEX idx_users_email ON Users.Users(Email); -- Creates an index for email, prevents doubles and makes searching through email faster

CREATE INDEX idx_users_role ON Users.Users(Role); -- Creates an index to search for roles (A/C) 

CREATE INDEX idx_users_email_lockedout ON Users.Users(Email, IsLockedOut); -- Creates an index to search for email + lock status

-- LoginLogs Table
CREATE INDEX idx_loginlogs_email ON Users.LoginLogs(Email); -- Creates an index for emails

CREATE INDEX idx_loginlogs_ipaddress ON Users.LoginLogs(IPAddress); -- Creates an index for IP Address

CREATE INDEX idx_loginlogs_attemptedat ON Users.LoginLogs(AttemptedAt); -- Creates an index for login attempts and timestamps 




