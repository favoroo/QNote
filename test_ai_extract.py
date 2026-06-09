import requests
import json
import re
from datetime import datetime
from pathlib import Path

# ============================================================
# 用户配置区（直接修改这里）
# ============================================================

# --- 模型配置 ---
# 如果 OVERRIDE_MODEL_* 不为空，则覆盖 defaults.dart 中的配置
OVERRIDE_MODEL_NAME = ''          # 覆盖模型名称，如 'agnes-2.0-flash'
OVERRIDE_API_KEY = ''             # 覆盖 API Key
OVERRIDE_BASE_URL = ''            # 覆盖 API 地址，如 'https://apihub.agnes-ai.com/v1'

# --- 请求参数 ---
TEMPERATURE = 0.01
MAX_TOKENS = 1024
TIMEOUT = 60

# --- 测试用例（直接在这里增删改） ---
TEST_CASES = [
    '昨晚十点睡，睡了八个小时',
    # '吃了一碗螺蛳粉，花了10元',
    # '早上吃了玉米鸡蛋油条',
    # '昨晚11点半才睡，睡得极差',
    # '今天下午喝了杯美式，花了18元',
    # '昨晚一点才睡着，今天早上吃了米粉',
    # '状态不错，头脑清醒',
    # '感觉有点累，头有点晕',
    # '今天头痛得厉害，吃了布洛芬',
]

# ============================================================
# 自动从 defaults.dart 同步配置（下方代码，一般无需修改）
# ============================================================

DEFAULTS_FILE = Path(__file__).parent / 'lib' / 'config' / 'defaults.dart'

# 供应商默认 Base URL 映射
VENDOR_BASE_URLS = {
    'agnes': 'https://apihub.agnes-ai.com/v1',
    'longcat': 'https://api.longcat.chat/openai/v1',
    'gemini': 'https://generativelanguage.googleapis.com',
}

def parse_defaults_dart(file_path: Path) -> dict:
    """解析 defaults.dart，提取提示词、Schema 和 AI 配置"""
    content = file_path.read_text(encoding='utf-8')
    result = {}
    
    # 1. 提取 unified_extraction 提示词
    match = re.search(r"'unified_extraction':\s*'''(.*?)'''", content, re.DOTALL)
    if match:
        result['unified_extraction_prompt'] = match.group(1)
    
    # 2. 提取 defaultAiConfigs 中的第一个配置
    ai_match = re.search(
        r"final defaultAiConfigs.*?AiConfig\(\s*id:\s*'([^']+)',.*?modelName:\s*'([^']+)',.*?apiKey:\s*'([^']+)',.*?baseUrl:\s*'([^']*)',.*?vendorId:\s*'([^']*)'",
        content,
        re.DOTALL,
    )
    if ai_match:
        result['ai_config'] = {
            'id': ai_match.group(1),
            'model': ai_match.group(2),
            'api_key': ai_match.group(3),
            'base_url': ai_match.group(4),
            'vendor_id': ai_match.group(5),
        }
    
    # 3. 解析 defaultShortcutConfigs 生成 Schema JSON
    schema = parse_shortcut_configs(content)
    if schema:
        result['schema'] = schema
    
    return result

def extract_dart_block(text: str, start: int, initial_depth: int = 0) -> str:
    """从 start 位置开始，提取平衡括号内的完整代码块"""
    depth_paren = initial_depth
    depth_bracket = 0
    i = start
    while i < len(text):
        ch = text[i]
        if ch == '(':
            depth_paren += 1
        elif ch == ')':
            depth_paren -= 1
            if depth_paren == 0 and depth_bracket == 0:
                return text[start:i+1]
        elif ch == '[':
            depth_bracket += 1
        elif ch == ']':
            depth_bracket -= 1
        i += 1
    return text[start:]

def parse_shortcut_configs(content: str) -> list:
    """从 Dart 源码解析快捷方式配置，生成 Schema JSON"""
    configs = []
    
    start_match = re.search(r'final defaultShortcutConfigs\s*=\s*<ShortcutConfig>\[', content)
    if not start_match:
        return []
    
    start_pos = start_match.end()
    end_match = re.search(r'\];', content[start_pos:])
    if not end_match:
        return []
    
    configs_block = content[start_pos:start_pos + end_match.start()]
    
    pos = 0
    while True:
        idx = configs_block.find('ShortcutConfig(', pos)
        if idx == -1:
            break
        
        inner_start = idx + len('ShortcutConfig(')
        depth_paren = 1
        depth_bracket = 0
        i = inner_start
        while i < len(configs_block):
            ch = configs_block[i]
            if ch == '(':
                depth_paren += 1
            elif ch == ')':
                depth_paren -= 1
                if depth_paren == 0 and depth_bracket == 0:
                    block = configs_block[inner_start:i]
                    break
            elif ch == '[':
                depth_bracket += 1
            elif ch == ']':
                depth_bracket -= 1
            i += 1
        else:
            break
        
        id_match = re.search(r"id:\s*'([^']+)'", block)
        name_match = re.search(r"name:\s*'([^']+)'", block)
        
        if id_match and name_match:
            config = {
                'id': id_match.group(1),
                'name': name_match.group(1),
            }
            
            fields_match = re.search(r"fields:\s*\[", block)
            if fields_match:
                fields_inner_start = fields_match.end()
                f_depth = 1
                j = fields_inner_start
                while j < len(block) and f_depth > 0:
                    if block[j] == '[':
                        f_depth += 1
                    elif block[j] == ']':
                        f_depth -= 1
                        if f_depth == 0:
                            fields_block = block[fields_inner_start:j]
                            fields = parse_fields(fields_block)
                            if fields:
                                config['fields'] = fields
                            break
                    j += 1
            
            categories_match = re.search(r"categories:\s*\[", block)
            if categories_match:
                cat_inner_start = categories_match.end()
                c_depth = 1
                j = cat_inner_start
                while j < len(block) and c_depth > 0:
                    if block[j] == '[':
                        c_depth += 1
                    elif block[j] == ']':
                        c_depth -= 1
                        if c_depth == 0:
                            cat_block = block[cat_inner_start:j]
                            categories = parse_categories(cat_block)
                            if categories:
                                config['categories'] = categories
                            break
                    j += 1
            
            configs.append(config)
        
        pos = i + 1
    
    return configs

def parse_fields(fields_str: str) -> list:
    """解析字段定义"""
    fields = []
    pos = 0
    
    while True:
        idx = fields_str.find('ShortcutField(', pos)
        if idx == -1:
            break
        
        inner_start = idx + len('ShortcutField(')
        depth_paren = 1
        depth_bracket = 0
        i = inner_start
        while i < len(fields_str):
            ch = fields_str[i]
            if ch == '(':
                depth_paren += 1
            elif ch == ')':
                depth_paren -= 1
                if depth_paren == 0 and depth_bracket == 0:
                    block = fields_str[inner_start:i]
                    break
            elif ch == '[':
                depth_bracket += 1
            elif ch == ']':
                depth_bracket -= 1
            i += 1
        else:
            break
        
        id_match = re.search(r"id:\s*'([^']+)'", block)
        label_match = re.search(r"label:\s*'([^']+)'", block)
        type_match = re.search(r"type:\s*'([^']+)'", block)
        options_match = re.search(r"options:\s*\[", block)
        allow_custom_match = re.search(r"allowCustom:\s*(true|false)", block)
        
        if id_match and label_match and type_match:
            field = {
                'id': id_match.group(1),
                'name': label_match.group(1),
                'type': type_match.group(1),
            }
            
            if options_match:
                opt_inner = options_match.end()
                o_depth = 1
                j = opt_inner
                while j < len(block) and o_depth > 0:
                    if block[j] == '[':
                        o_depth += 1
                    elif block[j] == ']':
                        o_depth -= 1
                        if o_depth == 0:
                            options_content = block[opt_inner:j]
                            if options_content.strip():
                                options = re.findall(r"'([^']+)'", options_content)
                                field['options'] = options
                            break
                    j += 1
            
            if allow_custom_match and allow_custom_match.group(1) == 'true':
                field['allowCustom'] = True
            
            fields.append(field)
        
        pos = i + 1
    
    return fields

def parse_categories(categories_str: str) -> list:
    """解析分类定义"""
    categories = []
    pos = 0
    
    while True:
        idx = categories_str.find('ShortcutCategory(', pos)
        if idx == -1:
            break
        
        block = extract_dart_block(categories_str, idx + len('ShortcutCategory('))
        
        id_match = re.search(r"id:\s*'([^']+)'", block)
        name_match = re.search(r"name:\s*'([^']+)'", block)
        fields_match = re.search(r"fields:\s*\[", block)
        
        if id_match and name_match:
            category = {
                'id': id_match.group(1),
                'name': name_match.group(1),
            }
            
            if fields_match:
                fields_start = fields_match.end()
                fields_block = extract_dart_block(block, fields_start)
                fields = parse_fields(fields_block)
                if fields:
                    category['fields'] = fields
            
            categories.append(category)
        
        pos = idx + 1
    
    return categories

# 解析 defaults.dart
defaults_data = parse_defaults_dart(DEFAULTS_FILE)

# 从 defaults.dart 获取 AI 配置（用户覆盖优先）
_ai_config = defaults_data.get('ai_config', {})
vendor_id = _ai_config.get('vendor_id', '')

MODEL_NAME = OVERRIDE_MODEL_NAME or _ai_config.get('model', '')
API_KEY = OVERRIDE_API_KEY or _ai_config.get('api_key', '')
_base_url = OVERRIDE_BASE_URL or _ai_config.get('base_url', '')
BASE_URL = _base_url or VENDOR_BASE_URLS.get(vendor_id, 'https://api.longcat.chat/openai/v1')

# 从 defaults.dart 获取提示词和 Schema
UNIFIED_EXTRACTION_PROMPT = defaults_data.get('unified_extraction_prompt', '')
SCHEMA = json.dumps(defaults_data.get('schema', []), ensure_ascii=False, indent=2)

def get_context_str():
    now = datetime.now()
    weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日']
    return {
        'date': now.strftime('%Y-%m-%d'),
        'time': now.strftime('%H:%M'),
        'weekday': weekdays[now.weekday()],
    }

def call_ai(user_input: str) -> dict:
    context_str = get_context_str()
    
    # 将 Dart 占位符转换为 Python format 占位符
    prompt = UNIFIED_EXTRACTION_PROMPT.replace('{contextStr}', '{context_str}')
    
    # 转义所有其他 { } 以避免 Python format 误解析
    prompt = prompt.replace('{context_str}', '___CONTEXT___')
    prompt = prompt.replace('{schema}', '___SCHEMA___')
    prompt = prompt.replace('{', '{{').replace('}', '}}')
    prompt = prompt.replace('___CONTEXT___', '{context_str}')
    prompt = prompt.replace('___SCHEMA___', '{schema}')
    
    system_prompt = prompt.format(
        context_str=str(context_str),
        schema=SCHEMA,
    )
    
    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {API_KEY}',
    }
    
    payload = {
        'model': MODEL_NAME,
        'messages': [
            {'role': 'system', 'content': system_prompt},
            {'role': 'user', 'content': user_input},
        ],
        'temperature': TEMPERATURE,
        'max_tokens': MAX_TOKENS,
        'response_format': {'type': 'json_object'},
    }
    
    response = requests.post(
        f'{BASE_URL}/chat/completions',
        headers=headers,
        json=payload,
        timeout=TIMEOUT,
    )
    
    data = response.json()
    
    if 'error' in data:
        raise Exception(f"API Error: {data['error']}")
    
    if 'choices' not in data or not data['choices']:
        raise Exception(f"Unexpected response: {json.dumps(data, ensure_ascii=False, indent=2)}")
    
    message = data['choices'][0].get('message', {})
    content = message.get('content')
    
    if content is None:
        raise Exception(f"No content in response: {json.dumps(data, ensure_ascii=False, indent=2)}")
    
    return data

def main():
    print('=' * 60)
    print('AI 提取测试工具')
    print('=' * 60)
    print(f'模型: {MODEL_NAME}')
    print(f'API: {BASE_URL}')
    print(f'当前时间: {datetime.now().strftime("%Y-%m-%d %H:%M")}')
    print(f'测试用例数: {len(TEST_CASES)}')
    print('=' * 60)
    print()
    
    for i, user_input in enumerate(TEST_CASES, 1):
        print(f'[{i}/{len(TEST_CASES)}] 输入: {user_input}')
        print('-' * 60)
        
        try:
            response = call_ai(user_input)
            content = response['choices'][0]['message']['content']
            
            print('原始输出:')
            print(content)
            print()
            
            try:
                json_result = json.loads(content)
                
                if isinstance(json_result, dict) and 'results' in json_result:
                    results = json_result['results']
                elif isinstance(json_result, list):
                    results = json_result
                else:
                    results = [json_result]
                
                print('解析后结果:')
                print(json.dumps(results, ensure_ascii=False, indent=2))
            except json.JSONDecodeError as e:
                print(f'JSON 解析失败: {e}')
            
        except Exception as e:
            import traceback
            print(f'错误: {e}')
            traceback.print_exc()
        
        print()
        print('=' * 60)
        print()
    
    print('测试完成!')

if __name__ == '__main__':
    main()
