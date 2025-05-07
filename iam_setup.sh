#!/bin/bash

# Description: Automates user and group creation from a CSV input file
#              with temporary passwords and enforced complexity on first login
# Usage: ./iam_setup.sh [optional_csv_file]
# Default input file is users.txt
# Check if email is provided

if [[ -z "$1" ]]; then
  echo "Usage: $0 <admin_email> [input_file]"
  exit 1
fi

ADMIN_EMAIL="$1"                      # Required: Email address
INPUT_FILE="${2:-users.txt}"          # Optional: Input file, defaults to users.txt
LOG_FILE="iam_setup.log" 
# Root check
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (with sudo)." >&2
    exit 1
fi

# Input file check
if [ ! -f "$INPUT_FILE" ]; then
    echo "Input file '$INPUT_FILE' not found."
    exit 1
fi

# Log header
{
    echo "==== IAM Setup Log - $(date '+%Y-%m-%d %H:%M:%S') ===="
    echo "Script version: 2.1 (Complexity on first login)"
} >> "$LOG_FILE"

# Function to generate simple temporary password (8 chars, letters+numbers)
generate_temp_password() {
    TEMP_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8)
    echo "$TEMP_PASSWORD"
}

# Function to enforce password complexity on first login
enforce_complex_password() {
    local username="$1"
    local attempts=0
    local max_attempts=3
    
    echo "You must change your temporary password. Complexity requirements:"
    echo "- Minimum 12 characters"
    echo "- At least one uppercase letter"
    echo "- At least one digit"
    echo "- At least one special character (!@#$%^&*)"
    
    while [ $attempts -lt $max_attempts ]; do
        read -sp "Enter new password: " new_pass
        echo
        
        # Complexity checks
        if [[ ${#new_pass} -lt 12 ]]; then
            echo "Password too short (min 12 characters)."
        elif [[ ! "$new_pass" =~ [A-Z] ]]; then
            echo "Password must contain at least one uppercase letter."
        elif [[ ! "$new_pass" =~ [0-9] ]]; then
            echo "Password must contain at least one digit."
        elif [[ ! "$new_pass" =~ [\!\@\#\$\%\^\&\*] ]]; then
            echo "Password must contain at least one special character."
        else
            # Set new password if complexity met
            if echo "$username:$new_pass" | chpasswd 2>/dev/null; then
                echo "Password changed successfully!"
                echo "$(date '+%Y-%m-%d %H:%M:%S') - $username changed password successfully" >> "$LOG_FILE"
                return 0
            else
                echo "Error: Failed to set password. Please contact admin."
                return 1
            fi
        fi
        
        attempts=$((attempts + 1))
        echo "Attempts remaining: $((max_attempts - attempts))"
    done
    
    echo "Maximum attempts reached. Account locked."
    passwd -l "$username" >> "$LOG_FILE" 2>&1
    return 1
}

# Main user processing loop
while IFS=',' read -r username fullname group email || [ -n "$username" ]; do
    [[ "$username" == "username" || -z "$username" ]] && continue

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Processing user: $username" | tee -a "$LOG_FILE"

    # Group management
    if ! getent group "$group" > /dev/null; then
        groupadd "$group" 2>> "$LOG_FILE" && \
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Group '$group' created." | tee -a "$LOG_FILE"
    fi

    # User creation
    if ! id "$username" &>/dev/null; then
        if useradd -m -c "$fullname" -g "$group" "$username" 2>> "$LOG_FILE"; then
            TEMP_PASSWORD=$(generate_temp_password)
            echo "$username:$TEMP_PASSWORD" | chpasswd 2>> "$LOG_FILE"
            
            # Force password change on first login
            chage -d 0 "$username" 2>> "$LOG_FILE"
            passwd --expire "$username" 2>> "$LOG_FILE"
            
            echo "$(date '+%Y-%m-%d %H:%M:%S') - User '$username' created. Temp password: $TEMP_PASSWORD" | tee -a "$LOG_FILE"
            
            # Home directory permissions
            chown "$username:$group" "/home/$username"
            chmod 700 "/home/$username"
            
            # Email notification
            if [ -n "$email" ] && [ -f "email_server.py" ]; then
                python3 email_server.py "$email" "$fullname" "$username" "$TEMP_PASSWORD" && \
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Email sent to $email" | tee -a "$LOG_FILE"
            fi
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - User '$username' exists." | tee -a "$LOG_FILE"
    fi
done < "$INPUT_FILE"

# Completion
echo "==== Setup Completed - $(date '+%Y-%m-%d %H:%M:%S') ====" >> "$LOG_FILE"
echo "Sending Log File to Admin..."
python3 email_server.py "--Admin-alert" "$LOG_FILE" "$ADMIN_EMAIL" && \
echo "$(date '+%Y-%m-%d %H:%M:%S') - Logs  sent to Admin" | tee -a "$LOG_FILE"
echo "User setup complete. Check $LOG_FILE for details."
