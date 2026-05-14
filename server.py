#!/usr/bin/env python3
"""
Telegram Auto-Add Server - FIXED & IMPROVED VERSION
- Proper group joining and member adding
- Rate limited: 120 adds/day max
- Delay: 60 seconds between adds
- Anti-spam protection
"""

from flask import Flask, send_file, jsonify, request, redirect
from flask_cors import CORS
from telethon import TelegramClient, errors
from telethon.tl.functions.channels import InviteToChannelRequest
from telethon.tl.functions.messages import ImportChatInviteRequest
from telethon.sessions import StringSession
from telethon.tl.types import InputPeerUser, InputPeerChannel
import json
import os
import asyncio
import logging
import time
import random
import threading
import requests
from datetime import datetime, timedelta
from collections import defaultdict, deque

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

app = Flask(__name__)
CORS(app)

# ============================================
# CONFIGURATION - EDIT THESE VALUES
# ============================================
API_ID = 36274756  # YOUR API ID HERE
API_HASH = 'b70311a2b3547e1ce40e72081dc726dc'  # YOUR API HASH HERE
PORT = 10000

# Target groups to join and add members to
TARGET_GROUPS = [
    'Abe_armygroup',  # Username of target group
    'abe_army'        # Alternative group username
]

# Rate limiting
MAX_ADDS_PER_DAY = 120
MIN_DELAY_SECONDS = 60

# File paths
ACCOUNTS_FILE = 'accounts.json'
SETTINGS_FILE = 'auto_add_settings.json'
STATS_FILE = 'stats.json'

# Thread-safe storage
accounts = []
auto_add_settings = {}
running_tasks = {}
file_lock = threading.Lock()

# Rate limiting
daily_adds = defaultdict(lambda: {'count': 0, 'last_reset': '', 'adds': deque(maxlen=MAX_ADDS_PER_DAY)})
flood_waits = {}

stats = {
    'total_added': 0,
    'today_added': 0,
    'last_reset': datetime.now().strftime('%Y-%m-%d')
}

# ============================================
# FILE OPERATIONS
# ============================================
def load_json(path, default=None):
    if default is None:
        default = {}
    try:
        if os.path.exists(path):
            with open(path, 'r') as f:
                content = f.read().strip()
                return json.loads(content) if content else default
    except Exception as e:
        logger.error(f"Failed to load {path}: {e}")
    return default

def save_json(path, data):
    with file_lock:
        try:
            with open(path, 'w') as f:
                json.dump(data, f, indent=2, default=str)
        except Exception as e:
            logger.error(f"Failed to save {path}: {e}")

# ============================================
# TELEGRAM CLIENT FUNCTIONS
# ============================================
def get_client(acc):
    return TelegramClient(
        StringSession(acc['session']),
        API_ID,
        API_HASH,
        connection_retries=3,
        retry_delay=2,
        timeout=30,
        auto_reconnect=False
    )

# ============================================
# CORE AUTO-ADD WORKER# ============================================
def auto_add_worker(account):
    """Main auto-add worker - joins groups and adds members"""
    acc_id = account['id']
    acc_key = str(acc_id)
    account_name = account.get('name', 'Unknown')
    attempted_users = set()
    
    logger.info(f"🚀 Worker started for {account_name}")
    
    while True:
        try:
            # Check if enabled
            settings = auto_add_settings.get(acc_key, {})
            if not settings.get('enabled', True):
                time.sleep(30)
                continue
            
            # Check daily limit
            if not check_daily_limit(acc_id):
                logger.info(f"⏰ Daily limit reached for {account_name}")
                time.sleep(300)
                continue
            
            # Create event loop
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            
            try:
                client = get_client(account)
                
                # CONNECT
                logger.info(f"📡 Connecting {account_name}...")
                loop.run_until_complete(client.connect())
                
                if not loop.run_until_complete(client.is_user_authorized()):
                    logger.error(f"❌ {account_name} not authorized")
                    loop.close()
                    time.sleep(60)
                    continue
                
                me = loop.run_until_complete(client.get_me())
                worker_name = me.first_name or account_name
                logger.info(f"✅ Connected as {worker_name}")
                
                # JOIN TARGET GROUPS
                for target in TARGET_GROUPS:
                    try:
                        logger.info(f"📌 Joining group: {target}")
                        entity = loop.run_until_complete(client.get_entity(target))
                        loop.run_until_complete(client(InviteToChannelRequest(entity)))
                        logger.info(f"✅ Successfully joined {target}")
                        time.sleep(random.uniform(3, 6))
                    except errors.FloodWaitError as e:
                        logger.warning(f"⏳ Flood wait joining {target}: {e.seconds}s")
                        time.sleep(e.seconds)
                    except Exception as e:
                        if 'already' in str(e).lower() or 'participant' in str(e).lower():
                            logger.info(f"Already in {target}")
                        else:
                            logger.warning(f"Could not join {target}: {e}")
                
                # COLLECT USERS TO ADD
                logger.info("📊 Collecting users...")
                users_to_add = []
                
                # Get from contacts
                try:
                    contacts = loop.run_until_complete(client.get_contacts())
                    for contact in contacts:
                        if contact.id and not contact.bot and contact.id not in attempted_users:
                            users_to_add.append(contact.id)
                    logger.info(f"Found {len(users_to_add)} from contacts")
                except Exception as e:
                    logger.warning(f"Error getting contacts: {e}")
                
                # Get from dialogs
                try:
                    dialogs = loop.run_until_complete(client.get_dialogs(limit=100))
                    for dialog in dialogs:
                        if dialog.is_user and dialog.entity and not dialog.entity.bot:
                            if dialog.entity.id not in attempted_users and dialog.entity.id not in users_to_add:
                                users_to_add.append(dialog.entity.id)
                    logger.info(f"Total users collected: {len(users_to_add)}")
                except Exception as e:
                    logger.warning(f"Error getting dialogs: {e}")
                
                # Shuffle to avoid patterns
                random.shuffle(users_to_add)
                
                # GET PRIMARY GROUP
                primary_group = None
                for target in TARGET_GROUPS:
                    try:
                        primary_group = loop.run_until_complete(client.get_entity(target))
                        logger.info(f"✅ Using group: {target}")
                        break
                    except:
                        continue
                
                if not primary_group:
                    logger.error("❌ Cannot find any target group")
                    loop.close()
                    time.sleep(120)
                    continue
                
                # ADD USERS TO GROUP
                added_count = 0
                for user_id in users_to_add:
                    # Check if still enabled
                    if not auto_add_settings.get(acc_key, {}).get('enabled', True):
                        break
                    
                    # Check daily limit
                    if not check_daily_limit(acc_id):
                        break
                    
                    attempted_users.add(user_id)
                    
                    try:
                        # Delay between adds
                        delay = random.uniform(MIN_DELAY_SECONDS, MIN_DELAY_SECONDS * 1.3)
                        today_count = daily_adds[acc_key]['count']
                        logger.info(f"⏳ Waiting {delay:.0f}s ({today_count}/{MAX_ADDS_PER_DAY} today)")
                        time.sleep(delay)
                        
                        # Add user to group
                        user_entity = loop.run_until_complete(client.get_input_entity(user_id))
                        loop.run_until_complete(
                            client(InviteToChannelRequest(primary_group, [user_entity]))
                        )
                        
                        # Record success
                        record_add(acc_id, user_id)
                        stats['today_added'] += 1
                        stats['total_added'] += 1
                        added_count += 1
                        
                        logger.info(f"✅ Added {user_id} ({added_count} this session, {daily_adds[acc_key]['count']}/{MAX_ADDS_PER_DAY} today)")
                        
                    except errors.FloodWaitError as e:
                        logger.warning(f"⏳ Flood wait: {e.seconds}s")
                        time.sleep(e.seconds)
                        
                    except errors.UserPrivacyRestrictedError:
                        logger.debug(f"Privacy restricted: {user_id}")
                        continue
                        
                    except errors.UserAlreadyParticipantError:
                        logger.debug(f"Already in group: {user_id}")
                        continue
                        
                    except Exception as e:
                        logger.error(f"Error adding {user_id}: {str(e)[:100]}")
                        time.sleep(5)
                        continue
                
                # Clean up attempted users if too many
                if len(attempted_users) > 1000:
                    attempted_users.clear()
                
                # Save stats
                save_json(STATS_FILE, stats)
                save_json('daily_adds.json', dict(daily_adds))
                
                logger.info(f"✅ Cycle complete: Added {added_count} users")
                
                # Disconnect
                loop.run_until_complete(client.disconnect())
                
            except errors.FloodWaitError as e:
                logger.warning(f"⏳ Global flood wait: {e.seconds}s")
                time.sleep(e.seconds)
                
            except Exception as e:
                logger.error(f"Worker error: {e}")
                try:
                    loop.run_until_complete(client.disconnect())
                except:
                    pass
            finally:
                loop.close()
            
            # Wait between cycles
            if check_daily_limit(acc_id):
                rest = random.randint(180, 300)
                logger.info(f"😴 Resting {rest}s")
                time.sleep(rest)
            else:
                time.sleep(600)
                
        except Exception as e:
            logger.error(f"Critical error: {e}")
            time.sleep(120)

# ============================================
# RATE LIMITING FUNCTIONS
# ============================================
def check_daily_limit(account_id):
    """Check if account can still add today"""
    today = datetime.now().strftime('%Y-%m-%d')
    acc_key = str(account_id)
    
    if daily_adds[acc_key]['last_reset'] != today:
        daily_adds[acc_key] = {
            'count': 0,
            'last_reset': today,
            'adds': deque(maxlen=MAX_ADDS_PER_DAY)
        }
    
    return daily_adds[acc_key]['count'] < MAX_ADDS_PER_DAY

def record_add(account_id, user_id):
    """Record successful add"""
    acc_key = str(account_id)
    today = datetime.now().strftime('%Y-%m-%d')
    
    if daily_adds[acc_key]['last_reset'] != today:
        daily_adds[acc_key] = {
            'count': 0,
            'last_reset': today,
            'adds': deque(maxlen=MAX_ADDS_PER_DAY)
        }
    
    daily_adds[acc_key]['count'] += 1
    daily_adds[acc_key]['adds'].append({
        'user_id': user_id,
        'time': datetime.now().isoformat()
    })

# ============================================
# WORKER MANAGEMENT
# ============================================
def start_auto_add(account):
    """Start worker thread for account"""
    acc_key = str(account['id'])
    if acc_key in running_tasks and running_tasks[acc_key].is_alive():
        return
    
    thread = threading.Thread(
        target=auto_add_worker,
        args=(account,),
        daemon=True,
        name=f"Worker-{account.get('name', acc_key)}"
    )
    thread.start()
    running_tasks[acc_key] = thread
    logger.info(f"Started worker for {account.get('name', acc_key)}")

def remove_account(account_id, reason=""):
    """Remove account and cleanup"""
    global accounts
    acc = next((a for a in accounts if a['id'] == account_id), None)
    name = acc.get('name', str(account_id)) if acc else str(account_id)
    
    accounts = [a for a in accounts if a['id'] != account_id]
    auto_add_settings.pop(str(account_id), None)
    running_tasks.pop(str(account_id), None)
    daily_adds.pop(str(account_id), None)
    flood_waits.pop(str(account_id), None)
    
    save_json(ACCOUNTS_FILE, accounts)
    save_json(SETTINGS_FILE, auto_add_settings)
    
    logger.warning(f"Removed account: {name} - {reason}")
    return name

# ============================================
# FLASK ROUTES
# ============================================
@app.route('/')
def index():
    return redirect('/auto-add')

@app.route('/auto-add')
def auto_add_page():
    try:
        return send_file('auto_add.html')
    except:
        return "auto_add.html not found", 404

@app.route('/login')
def login_page():
    try:
        return send_file('login.html')
    except:
        return "login.html not found", 404

@app.route('/dashboard')
def dashboard_page():
    try:
        return send_file('dashboard.html')
    except:
        return "dashboard.html not found", 404

@app.route('/dash')
def dash_page():
    try:
        return send_file('dash.html')
    except:
        return "dash.html not found", 404

@app.route('/ping')
def ping():
    return jsonify({'status': 'ok'})

@app.route('/api/accounts')
def get_accounts():
    acc_list = []
    for acc in accounts:
        acc_key = str(acc['id'])
        today_adds = daily_adds[acc_key]['count'] if acc_key in daily_adds else 0
        
        acc_list.append({
            'id': acc['id'],
            'name': acc.get('name', 'Unknown'),
            'phone': acc.get('phone', ''),
            'username': acc.get('username', ''),
            'active': acc.get('active', True),
            'auto_add_enabled': auto_add_settings.get(acc_key, {}).get('enabled', True),
            'daily_adds': today_adds,
            'daily_limit': MAX_ADDS_PER_DAY,
            'remaining': max(0, MAX_ADDS_PER_DAY - today_adds)
        })
    return jsonify({'success': True, 'accounts': acc_list})

@app.route('/api/add-account', methods=['POST'])
def add_account():
    try:
        data = request.json
        phone = data.get('phone', '').strip()
        if not phone:
            return jsonify({'success': False, 'error': 'Phone number required'})
        if not phone.startswith('+'):
            phone = '+' + phone
        
        async def send_code():
            client = TelegramClient(StringSession(), API_ID, API_HASH)
            try:
                await client.connect()
                result = await client.send_code_request(phone)
                session_id = str(int(time.time() * 1000))
                
                temp_file = f'temp_{session_id}.json'
                with open(temp_file, 'w') as f:
                    json.dump({
                        'phone': phone,
                        'hash': result.phone_code_hash,
                        'session': client.session.save()
                    }, f)
                
                return {'success': True, 'session_id': session_id}
            except errors.FloodWaitError as e:
                return {'success': False, 'error': f'Too many attempts. Wait {e.seconds}s'}
            except Exception as e:
                return {'success': False, 'error': str(e)}
            finally:
                await client.disconnect()
        
        loop = asyncio.new_event_loop()
        result = loop.run_until_complete(send_code())
        loop.close()
        return jsonify(result)
        
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/verify-code', methods=['POST'])
def verify_code():
    try:
        data = request.json
        code = data.get('code', '').strip()
        session_id = data.get('session_id', '')
        password = data.get('password', '')
        
        temp_file = f'temp_{session_id}.json'
        if not os.path.exists(temp_file):
            return jsonify({'success': False, 'error': 'Session expired'})
        
        with open(temp_file, 'r') as f:
            session_data = json.load(f)
        
        async def verify():
            client = TelegramClient(
                StringSession(session_data['session']),
                API_ID,
                API_HASH
            )
            try:
                await client.connect()
                
                try:
                    await client.sign_in(
                        session_data['phone'],
                        code,
                        phone_code_hash=session_data['hash']
                    )
                except errors.SessionPasswordNeededError:
                    if not password:
                        return {'need_password': True}
                    await client.sign_in(password=password)
                
                me = await client.get_me()
                new_id = int(time.time() * 1000)
                
                new_account = {
                    'id': new_id,
                    'phone': me.phone or session_data['phone'],
                    'name': (me.first_name or '') + (' ' + me.last_name if me.last_name else ''),
                    'username': me.username or '',
                    'session': client.session.save(),
                    'active': True
                }
                
                accounts.append(new_account)
                save_json(ACCOUNTS_FILE, accounts)
                
                auto_add_settings[str(new_id)] = {
                    'enabled': True,
                    'target_group': TARGET_GROUPS[0]
                }
                save_json(SETTINGS_FILE, auto_add_settings)
                
                # Start worker
                start_auto_add(new_account)
                
                try:
                    os.remove(temp_file)
                except:
                    pass
                
                return {
                    'success': True,
                    'account': {
                        'id': new_id,
                        'name': new_account['name'],
                        'phone': new_account['phone']
                    }
                }
                
            except errors.PhoneCodeInvalidError:
                return {'success': False, 'error': 'Invalid code'}
            except errors.PhoneCodeExpiredError:
                return {'success': False, 'error': 'Code expired'}
            except Exception as e:
                return {'success': False, 'error': str(e)}
            finally:
                await client.disconnect()
        
        loop = asyncio.new_event_loop()
        result = loop.run_until_complete(verify())
        loop.close()
        return jsonify(result)
        
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/api/remove-account', methods=['POST'])
def api_remove_account():
    aid = request.json.get('accountId')
    name = remove_account(aid, "Manual removal")
    return jsonify({'success': True, 'message': f'Removed: {name}'})

@app.route('/api/auto-add-settings', methods=['GET', 'POST'])
def auto_add_settings_route():
    if request.method == 'GET':
        aid = request.args.get('accountId')
        acc_key = str(aid)
        settings = auto_add_settings.get(acc_key, {
            'enabled': False,
            'target_group': TARGET_GROUPS[0]
        })
        
        today_adds = daily_adds[acc_key]['count'] if acc_key in daily_adds else 0
        
        return jsonify({
            'success': True,
            'settings': settings,
            'daily_stats': {
                'added_today': today_adds,
                'daily_limit': MAX_ADDS_PER_DAY,
                'remaining': max(0, MAX_ADDS_PER_DAY - today_adds)
            }
        })
    
    # POST
    data = request.json
    aid = data.get('accountId')
    acc_key = str(aid)
    
    auto_add_settings[acc_key] = {
        'enabled': data.get('enabled', False),
        'target_group': data.get('target_group', TARGET_GROUPS[0])
    }
    save_json(SETTINGS_FILE, auto_add_settings)
    
    if data.get('enabled'):
        acc = next((a for a in accounts if a['id'] == aid), None)
        if acc:
            start_auto_add(acc)
    
    return jsonify({'success': True, 'message': 'Settings saved'})

@app.route('/api/stats')
def get_stats():
    today = datetime.now().strftime('%Y-%m-%d')
    if stats['last_reset'] != today:
        stats['today_added'] = 0
        stats['last_reset'] = today
    
    total_added = sum(daily_adds[k]['count'] for k in daily_adds 
                      if daily_adds[k]['last_reset'] == today)
    
    return jsonify({
        'success': True,
        'stats': stats,
        'total_today_all_accounts': total_added,
        'rate_limits': {
            'max_per_day': MAX_ADDS_PER_DAY,
            'min_delay_seconds': MIN_DELAY_SECONDS
        }
    })

# ============================================
# STARTUP
# ============================================
def keep_alive():
    """Keep server alive"""
    while True:
        time.sleep(240)

def restore_and_start():
    """Restore accounts on startup"""
    time.sleep(5)
    
    for acc in accounts:
        if acc.get('session'):
            try:
                client = get_client(acc)
                loop = asyncio.new_event_loop()
                
                async def check():
                    await client.connect()
                    try:
                        return await client.is_user_authorized()
                    finally:
                        await client.disconnect()
                
                authorized = loop.run_until_complete(check())
                loop.close()
                
                if authorized:
                    start_auto_add(acc)
                    time.sleep(2)
                else:
                    remove_account(acc['id'], "Not authorized")
            except:
                remove_account(acc['id'], "Failed check")
    
    logger.info(f"Server started with {len(accounts)} accounts")

# ============================================
# MAIN
# ============================================
if __name__ == '__main__':
    # Load saved data
    accounts = load_json(ACCOUNTS_FILE, [])
    auto_add_settings = load_json(SETTINGS_FILE, {})
    stats = load_json(STATS_FILE, stats)
    
    print(f"""
╔══════════════════════════════════╗
║   AUTO-ADD SERVER READY         ║
║   Max: {MAX_ADDS_PER_DAY} adds/day         ║
║   Delay: {MIN_DELAY_SECONDS}s between adds   ║
║   Target: {TARGET_GROUPS[0]}   ║
║   Port: {PORT}                   ║
╚══════════════════════════════════╝
    """)
    
    # Start background threads
    threading.Thread(target=keep_alive, daemon=True).start()
    threading.Thread(target=restore_and_start, daemon=True).start()
    
    # Run Flask
    app.run(host='0.0.0.0', port=PORT, debug=False)
